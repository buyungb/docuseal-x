"""
PDF Tag Extractor Service

Uses PyMuPDF (fitz) to accurately extract {{...}} tag positions from PDFs.
This service provides an HTTP API for the DocuSeal application to find
field tag positions in converted PDFs.
"""

import base64
import io
import re
import json
from typing import List, Dict, Any, Optional
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
import fitz  # PyMuPDF

app = FastAPI(
    title="PDF Tag Extractor",
    description="Extract {{...}} tag positions from PDF documents",
    version="1.0.0"
)

# Tag pattern: {{FieldName;type=TYPE;role=ROLE;...}}
TAG_PATTERN = re.compile(r'\{\{([^}]+)\}\}')


class ExtractRequest(BaseModel):
    """Request model for tag extraction"""
    pdf_base64: str
    normalize_positions: bool = True  # Return positions as 0-1 ratios


class TagPosition(BaseModel):
    """Position of a tag in the PDF"""
    tag_content: str
    name: str
    type: str
    role: Optional[str] = None
    required: bool = True
    page: int
    x: float
    y: float
    w: float
    h: float
    raw_text: str


class ExtractResponse(BaseModel):
    """Response model for tag extraction"""
    success: bool
    tags: List[TagPosition]
    page_count: int
    message: Optional[str] = None


def parse_tag_attributes(tag_content: str) -> Dict[str, Any]:
    """
    Parse tag content like "BuyerSign;type=signature;role=Buyer;required=true"
    into a dictionary of attributes.
    """
    parts = tag_content.split(';')
    name = parts[0].strip() if parts else "Field"
    
    attrs = {
        'name': name,
        'type': 'text',  # default
        'role': None,
        'required': True,
    }
    
    for part in parts[1:]:
        if '=' in part:
            key, value = part.split('=', 1)
            key = key.strip().lower()
            value = value.strip()
            
            if key == 'type':
                attrs['type'] = normalize_field_type(value)
            elif key == 'role':
                attrs['role'] = value
            elif key == 'required':
                attrs['required'] = value.lower() in ('true', 'yes', '1')
            elif key == 'name':
                attrs['name'] = value
    
    # If name is empty or contains '=', generate a name from type
    if not attrs['name'] or '=' in attrs['name']:
        attrs['name'] = f"{attrs['type'].title()} Field"
    
    return attrs


def normalize_field_type(field_type: str) -> str:
    """Normalize field type aliases"""
    type_map = {
        'sig': 'signature',
        'sign': 'signature',
        'init': 'initials',
        'check': 'checkbox',
        'multi': 'multiple',
        'sel': 'select',
        'img': 'image',
        'num': 'number',
        'datenow': 'date',  # Keep as date for positioning, metadata will have datenow
    }
    return type_map.get(field_type.lower(), field_type.lower())


def extract_tags_from_pdf(pdf_data: bytes, normalize: bool = True) -> Dict[str, Any]:
    """
    Extract {{...}} tags from PDF with their exact positions.
    
    Args:
        pdf_data: Raw PDF bytes
        normalize: If True, return positions as 0-1 ratios; otherwise pixel coordinates
    
    Returns:
        Dictionary with tags and metadata
    """
    doc = fitz.open(stream=pdf_data, filetype="pdf")
    tags = []
    
    for page_num in range(doc.page_count):
        page = doc[page_num]
        page_width = page.rect.width
        page_height = page.rect.height
        
        # Get text with position information
        # Using "dict" output gives us detailed positioning
        text_dict = page.get_text("dict", flags=fitz.TEXT_PRESERVE_WHITESPACE)
        
        # Also get raw text blocks for fallback
        text_blocks = page.get_text("blocks")
        
        # First approach: Search using text spans (most accurate)
        for block in text_dict.get("blocks", []):
            if block.get("type") != 0:  # Skip non-text blocks
                continue
            
            for line in block.get("lines", []):
                # Combine all spans in the line to handle split tags
                line_text = ""
                line_spans = []
                
                for span in line.get("spans", []):
                    line_text += span.get("text", "")
                    line_spans.append(span)
                
                # Find tags in the combined line text
                for match in TAG_PATTERN.finditer(line_text):
                    tag_content = match.group(1)
                    tag_start = match.start()
                    tag_end = match.end()
                    
                    # Find the bounding box by looking at spans that contain the tag
                    bbox = find_tag_bbox(line_spans, tag_start, tag_end, line_text)
                    
                    if bbox:
                        attrs = parse_tag_attributes(tag_content)
                        
                        if normalize:
                            tag_pos = TagPosition(
                                tag_content=tag_content,
                                name=attrs['name'],
                                type=attrs['type'],
                                role=attrs['role'],
                                required=attrs['required'],
                                page=page_num,
                                x=bbox[0] / page_width,
                                y=bbox[1] / page_height,
                                w=(bbox[2] - bbox[0]) / page_width,
                                h=(bbox[3] - bbox[1]) / page_height,
                                raw_text=match.group(0)
                            )
                        else:
                            tag_pos = TagPosition(
                                tag_content=tag_content,
                                name=attrs['name'],
                                type=attrs['type'],
                                role=attrs['role'],
                                required=attrs['required'],
                                page=page_num,
                                x=bbox[0],
                                y=bbox[1],
                                w=bbox[2] - bbox[0],
                                h=bbox[3] - bbox[1],
                                raw_text=match.group(0)
                            )
                        
                        tags.append(tag_pos)
        
        # Second approach: Search in text blocks if no tags found via spans
        if not tags:
            for block in text_blocks:
                if len(block) < 5:
                    continue
                
                x0, y0, x1, y1, text, block_no, block_type = block[:7]
                
                if block_type != 0:  # Skip non-text blocks
                    continue
                
                for match in TAG_PATTERN.finditer(text):
                    tag_content = match.group(1)
                    attrs = parse_tag_attributes(tag_content)
                    
                    # Estimate position within block based on character position
                    char_ratio = match.start() / max(len(text), 1)
                    tag_x = x0 + (x1 - x0) * char_ratio
                    tag_w = (x1 - x0) * (len(match.group(0)) / max(len(text), 1))
                    
                    if normalize:
                        tag_pos = TagPosition(
                            tag_content=tag_content,
                            name=attrs['name'],
                            type=attrs['type'],
                            role=attrs['role'],
                            required=attrs['required'],
                            page=page_num,
                            x=tag_x / page_width,
                            y=y0 / page_height,
                            w=max(tag_w / page_width, 0.15),  # Minimum width
                            h=(y1 - y0) / page_height,
                            raw_text=match.group(0)
                        )
                    else:
                        tag_pos = TagPosition(
                            tag_content=tag_content,
                            name=attrs['name'],
                            type=attrs['type'],
                            role=attrs['role'],
                            required=attrs['required'],
                            page=page_num,
                            x=tag_x,
                            y=y0,
                            w=max(tag_w, 100),
                            h=y1 - y0,
                            raw_text=match.group(0)
                        )
                    
                    tags.append(tag_pos)
    
    # Remove duplicates (same tag at same position)
    unique_tags = []
    seen = set()
    for tag in tags:
        key = (tag.name, tag.page, round(tag.x, 2), round(tag.y, 2))
        if key not in seen:
            seen.add(key)
            unique_tags.append(tag)
    
    doc.close()
    
    return {
        'tags': unique_tags,
        'page_count': doc.page_count if doc else 0
    }


def find_tag_bbox(spans: List[Dict], tag_start: int, tag_end: int, full_text: str) -> Optional[tuple]:
    """
    Find the bounding box for a tag given the spans and character positions.
    
    Returns (x0, y0, x1, y1) or None if not found.
    """
    if not spans:
        return None
    
    # Track character position across spans
    char_pos = 0
    start_bbox = None
    end_bbox = None
    
    for span in spans:
        span_text = span.get("text", "")
        span_start = char_pos
        span_end = char_pos + len(span_text)
        bbox = span.get("bbox")
        
        if not bbox:
            char_pos = span_end
            continue
        
        # Check if tag starts in this span
        if span_start <= tag_start < span_end:
            start_bbox = bbox
        
        # Check if tag ends in this span
        if span_start < tag_end <= span_end:
            end_bbox = bbox
        
        char_pos = span_end
    
    if start_bbox and end_bbox:
        return (
            start_bbox[0],  # x0 from start
            min(start_bbox[1], end_bbox[1]),  # y0
            end_bbox[2],  # x1 from end
            max(start_bbox[3], end_bbox[3])  # y1
        )
    elif start_bbox:
        return start_bbox
    elif end_bbox:
        return end_bbox
    elif spans:
        # Fallback: use first span's bbox
        first_bbox = spans[0].get("bbox")
        if first_bbox:
            return first_bbox
    
    return None


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy", "service": "pdf-tag-extractor"}


@app.post("/extract-tags", response_model=ExtractResponse)
async def extract_tags(request: ExtractRequest):
    """
    Extract {{...}} tags from a PDF document.
    
    The PDF should be provided as a base64-encoded string.
    Returns a list of tags with their positions.
    """
    try:
        # Decode base64 PDF
        try:
            pdf_data = base64.b64decode(request.pdf_base64)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"Invalid base64 encoding: {str(e)}")
        
        # Validate it's a PDF
        if not pdf_data.startswith(b'%PDF'):
            raise HTTPException(status_code=400, detail="Invalid PDF file")
        
        # Extract tags
        result = extract_tags_from_pdf(pdf_data, normalize=request.normalize_positions)
        
        return ExtractResponse(
            success=True,
            tags=result['tags'],
            page_count=result['page_count'],
            message=f"Found {len(result['tags'])} tags"
        )
    
    except HTTPException:
        raise
    except Exception as e:
        return ExtractResponse(
            success=False,
            tags=[],
            page_count=0,
            message=f"Error extracting tags: {str(e)}"
        )


@app.post("/extract-text")
async def extract_text(request: ExtractRequest):
    """
    Extract all text from a PDF (for debugging).
    """
    try:
        pdf_data = base64.b64decode(request.pdf_base64)
        doc = fitz.open(stream=pdf_data, filetype="pdf")
        
        pages = []
        for page_num in range(doc.page_count):
            page = doc[page_num]
            pages.append({
                "page": page_num,
                "text": page.get_text(),
                "width": page.rect.width,
                "height": page.rect.height
            })
        
        doc.close()
        return {"success": True, "pages": pages}
    
    except Exception as e:
        return {"success": False, "error": str(e)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
