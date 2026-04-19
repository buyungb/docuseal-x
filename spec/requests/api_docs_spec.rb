# frozen_string_literal: true

describe 'Public API documentation pages' do
  describe 'GET /api-docs' do
    it 'returns HTML with rendered API reference' do
      get '/api-docs'

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include('X-Auth-Token')
      expect(response.body).to include('markdown-body')
    end

    it 'returns not modified when etag matches' do
      get '/api-docs'
      etag = response.headers['ETag']
      expect(etag).to be_present

      get '/api-docs', headers: { 'If-None-Match' => etag }
      expect(response).to have_http_status(:not_modified)
    end
  end

  describe 'GET /docs/template-tags' do
    it 'returns HTML with template tag documentation' do
      get '/docs/template-tags'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('markdown-body')
    end
  end
end
