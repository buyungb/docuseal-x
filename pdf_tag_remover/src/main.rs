use actix_web::{web, App, HttpResponse, HttpServer};
use base64::{engine::general_purpose::STANDARD, Engine};
use lopdf::{Document, Object, Stream};
use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
struct RemoveTagsRequest {
    pdf_base64: String,
    #[serde(default)]
    tag_pattern: Option<String>,
}

#[derive(Debug, Serialize)]
struct RemoveTagsResponse {
    pdf_base64: String,
    tags_removed: usize,
    success: bool,
    message: String,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    success: bool,
    message: String,
}

/// Remove {{...}} tags from PDF content streams
fn remove_tags_from_pdf(pdf_data: &[u8], pattern: Option<&str>) -> Result<(Vec<u8>, usize), String> {
    let mut doc = Document::load_mem(pdf_data)
        .map_err(|e| format!("Failed to load PDF: {}", e))?;
    
    // Default pattern matches {{...}} tags
    let tag_regex = Regex::new(pattern.unwrap_or(r"\{\{[^}]+\}\}"))
        .map_err(|e| format!("Invalid regex pattern: {}", e))?;
    
    let mut total_removed = 0;
    
    // Collect all object IDs that are streams
    let stream_ids: Vec<_> = doc.objects.keys().cloned().collect();
    
    for obj_id in stream_ids {
        if let Ok(Object::Stream(ref mut stream)) = doc.get_object_mut(obj_id) {
            let removed = process_content_stream(stream, &tag_regex);
            total_removed += removed;
        }
    }
    
    // Save the modified PDF
    let mut output = Vec::new();
    doc.save_to(&mut output)
        .map_err(|e| format!("Failed to save PDF: {}", e))?;
    
    Ok((output, total_removed))
}

/// Process a content stream and remove tag patterns
fn process_content_stream(stream: &mut Stream, tag_regex: &Regex) -> usize {
    let mut removed = 0;
    
    // Try to decompress if needed
    let _ = stream.decompress();
    
    // Get the content
    let content = &stream.content;
    let content_str = String::from_utf8_lossy(content);
    
    // Find and count tags
    let original_count = tag_regex.find_iter(&content_str).count();
    
    if original_count > 0 {
        log::info!("Found {} tags in stream", original_count);
        
        // Replace tags with spaces (preserves layout)
        let modified = tag_regex.replace_all(&content_str, |caps: &regex::Captures| {
            // Replace with spaces of same length to maintain positioning
            " ".repeat(caps[0].len())
        });
        
        removed = original_count;
        
        // Update the stream content
        stream.content = modified.as_bytes().to_vec();
        
        // Remove compression since we modified content
        stream.dict.remove(b"Filter");
        stream.dict.remove(b"DecodeParms");
        stream.dict.set("Length", Object::Integer(stream.content.len() as i64));
    }
    
    removed
}

async fn remove_tags(req: web::Json<RemoveTagsRequest>) -> HttpResponse {
    log::info!("Received remove_tags request, PDF base64 length: {}", req.pdf_base64.len());
    
    // Decode base64 PDF
    let pdf_data = match STANDARD.decode(&req.pdf_base64) {
        Ok(data) => data,
        Err(e) => {
            log::error!("Failed to decode base64: {}", e);
            return HttpResponse::BadRequest().json(ErrorResponse {
                success: false,
                message: format!("Invalid base64 data: {}", e),
            });
        }
    };
    
    log::info!("Decoded PDF size: {} bytes", pdf_data.len());
    
    // Process the PDF
    match remove_tags_from_pdf(&pdf_data, req.tag_pattern.as_deref()) {
        Ok((modified_pdf, tags_removed)) => {
            log::info!("Successfully removed {} tags", tags_removed);
            
            let pdf_base64 = STANDARD.encode(&modified_pdf);
            
            HttpResponse::Ok().json(RemoveTagsResponse {
                pdf_base64,
                tags_removed,
                success: true,
                message: format!("Removed {} tags from PDF", tags_removed),
            })
        }
        Err(e) => {
            log::error!("Failed to process PDF: {}", e);
            HttpResponse::InternalServerError().json(ErrorResponse {
                success: false,
                message: e,
            })
        }
    }
}

async fn health() -> HttpResponse {
    HttpResponse::Ok().json(serde_json::json!({
        "status": "healthy",
        "service": "pdf_tag_remover"
    }))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));
    
    let port = std::env::var("PORT").unwrap_or_else(|_| "8081".to_string());
    let bind_addr = format!("0.0.0.0:{}", port);
    
    log::info!("Starting PDF Tag Remover service on {}", bind_addr);
    
    HttpServer::new(|| {
        App::new()
            .route("/health", web::get().to(health))
            .route("/remove_tags", web::post().to(remove_tags))
            .app_data(web::JsonConfig::default().limit(100 * 1024 * 1024)) // 100MB limit
    })
    .bind(&bind_addr)?
    .run()
    .await
}
