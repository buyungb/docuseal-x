# frozen_string_literal: true

module Aplindo
  class LicenseClient
    Error = Class.new(StandardError)

    USER_AGENT = 'DocuSeal Aplindo License Client'
    DEFAULT_TIMEOUT = 15

    def initialize(base_url: Docuseal::APLINDO_LICENSE_API_URL)
      @base_url = base_url.to_s.chomp('/')
    end

    def create_checkout_session(customer_email:, seats:, amount_idr:, product_slug:)
      post('/v1/checkout/sessions', {
             product_slug: product_slug,
             customer_email: customer_email,
             seats: seats.to_i,
             amount_idr: format_amount(amount_idr)
           })
    end

    def activate(key:, machine_id:, app_version: Docuseal.version)
      post('/v1/licenses/activate', {
             key: key,
             machine_id: machine_id,
             app_version: app_version
           })
    end

    def heartbeat(token:, machine_id:)
      post('/v1/licenses/heartbeat', {
             token: token,
             machine_id: machine_id
           })
    end

    private

    def post(path, body)
      response = Faraday.post("#{@base_url}#{path}") do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Accept'] = 'application/json'
        req.headers['User-Agent'] = USER_AGENT
        req.body = body.to_json
        req.options.read_timeout = DEFAULT_TIMEOUT
        req.options.open_timeout = DEFAULT_TIMEOUT
      end

      parse_response(response)
    rescue Faraday::TimeoutError
      raise Error, 'License server timed out. Please try again.'
    rescue Faraday::ConnectionFailed
      raise Error, 'Could not reach the license server.'
    rescue Faraday::Error => e
      raise Error, e.message.to_s.truncate(200)
    end

    def parse_response(response)
      payload = parse_body(response.body)

      if response.status >= 400
        message = payload.is_a?(Hash) ? (payload[:error] || payload[:message]) : nil
        raise Error, (message.presence || "License server returned #{response.status}")
      end

      payload
    end

    def parse_body(body)
      return {} if body.blank?

      JSON.parse(body, symbolize_names: true)
    rescue JSON::ParserError
      raise Error, 'Invalid response from license server.'
    end

    def format_amount(amount)
      str = amount.to_s.strip
      return str if str.match?(/\A\d+\.\d{2}\z/)

      format('%.2f', str.to_d)
    end
  end
end
