# frozen_string_literal: true

module Submitters
  module CreateStampAttachment
    WIDTH = 400
    HEIGHT = 200

    TRANSPARENT_PIXEL = "\x89PNG\r\n\u001A\n\u0000\u0000\u0000\rIHDR\u0000" \
                        "\u0000\u0000\u0001\u0000\u0000\u0000\u0001\b\u0004" \
                        "\u0000\u0000\u0000\xB5\u001C\f\u0002\u0000\u0000\u0000" \
                        "\vIDATx\xDAc\xFC_\u000F\u0000\u0002\x83\u0001\x804\xC3ڨ" \
                        "\u0000\u0000\u0000\u0000IEND\xAEB`\x82"

    module_function

    def call(submitter, with_logo: true)
      attachment = build_attachment(submitter, with_logo:)

      attachment.save!

      attachment
    end

    def build_attachment(submitter, with_logo: true)
      image = generate_stamp_image(submitter, with_logo:)

      image_data = image.write_to_buffer('.png')

      checksum = Digest::MD5.base64digest(image_data)

      attachment = submitter.attachments.joins(:blob).find_by(blob: { checksum: })

      attachment || submitter.attachments_attachments.new(
        blob: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(image_data), filename: 'stamp.png'),
        metadata: { analyzed: true, identified: true, width: image.width, height: image.height }
      )
    end

    def generate_stamp_image(submitter, with_logo: true)
      logo =
        if with_logo
          load_logo_image(submitter)
        else
          Vips::Image.new_from_buffer(TRANSPARENT_PIXEL, '').resize(WIDTH)
        end

      logo = logo.resize([WIDTH / logo.width.to_f, HEIGHT / logo.height.to_f].min)

      base_layer = Vips::Image.black(WIDTH, HEIGHT).new_from_image([255, 255, 255]).copy(interpretation: :srgb)

      opacity_layer = Vips::Image.new_from_buffer(TRANSPARENT_PIXEL, '').resize(WIDTH)

      text = build_text_image(submitter)

      text_layer = text.new_from_image([0, 0, 0]).copy(interpretation: :srgb)
      text_layer = text_layer.bandjoin(text)

      base_layer = base_layer.composite(logo, 'over',
                                        x: (WIDTH - logo.width) / 2,
                                        y: (HEIGHT - logo.height) / 2)

      base_layer = base_layer.composite(opacity_layer, 'over')

      base_layer.composite(text_layer, 'over',
                           x: (WIDTH - text_layer.width) / 2,
                           y: (HEIGHT - text_layer.height) / 2)
    end

    def build_text_image(submitter)
      if submitter.completed_at
        time = I18n.l(submitter.completed_at.in_time_zone(submitter.submission.account.timezone),
                      format: :long,
                      locale: submitter.submission.account.locale)

        timezone = TimeUtils.timezone_abbr(submitter.submission.account.timezone, submitter.completed_at)
      end

      name = build_name(submitter)
      role = build_role(submitter)

      digitally_signed_by = I18n.t(:digitally_signed_by, locale: submitter.submission.account.locale)

      name = ERB::Util.html_escape(name)
      role = ERB::Util.html_escape(role)

      text = %(<span size="90">#{digitally_signed_by}:\n<b>#{name}</b>\n#{role}#{time} #{timezone}</span>)

      Vips::Image.text(text, width: WIDTH, height: HEIGHT, wrap: :'word-char')
    end

    def build_name(submitter)
      if submitter.name.present? && submitter.email.present?
        "#{submitter.name} #{submitter.email}"
      else
        submitter.name || submitter.email || submitter.phone
      end
    end

    def build_role(submitter)
      if submitter.submission.template_submitters.size > 1
        item = submitter.submission.template_submitters.find { |e| e['uuid'] == submitter.uuid }

        "#{I18n.t(:role, locale: submitter.account.locale)}: #{item['name']}\n"
      else
        ''
      end
    end

    def load_logo(submitter)
      account = submitter&.account || submitter&.submission&.account

      # Priority: 1. stamp_url (dedicated stamp image), 2. company_logo_url, 3. default
      stamp_url = account&.account_configs&.find_by(key: AccountConfig::STAMP_URL_KEY)&.value
      logo_url = stamp_url.presence || account&.account_configs&.find_by(key: AccountConfig::COMPANY_LOGO_URL_KEY)&.value

      if logo_url.present?
        data = download_image_bytes(logo_url)
        return StringIO.new(data) if data.present?
      end

      PdfIcons.stamp_logo_io
    end

    # Download an image URL into a byte string. Follows redirects, sends a
    # User-Agent (required by hosts like upload.wikimedia.org which otherwise
    # return an HTML error page), and rejects non-image responses so the caller
    # doesn't hand garbage to libvips.
    MAX_REDIRECTS = 5
    USER_AGENT = "SealRoute/#{Docuseal::VERSION rescue '1.0'} (+https://sealroute.com)".freeze
    IMAGE_MIME_PREFIX = 'image/'

    def download_image_bytes(url, redirects_remaining: MAX_REDIRECTS)
      require 'net/http'

      uri = URI(url)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = 10

      req = Net::HTTP::Get.new(uri.request_uri)
      req['User-Agent'] = USER_AGENT
      req['Accept'] = 'image/*'

      res = http.request(req)

      case res
      when Net::HTTPRedirection
        if redirects_remaining <= 0
          Rails.logger.warn("CreateStampAttachment: too many redirects for #{url}")
          return nil
        end
        next_url = URI.join(uri, res['location']).to_s
        return download_image_bytes(next_url, redirects_remaining: redirects_remaining - 1)
      when Net::HTTPSuccess
        content_type = res.content_type.to_s.downcase
        unless content_type.start_with?(IMAGE_MIME_PREFIX)
          Rails.logger.warn("CreateStampAttachment: #{url} returned non-image Content-Type=#{content_type.inspect}; ignoring")
          return nil
        end
        res.body
      else
        Rails.logger.warn("CreateStampAttachment: #{url} returned HTTP #{res.code}")
        nil
      end
    rescue StandardError => e
      Rails.logger.warn("CreateStampAttachment: failed to download #{url}: #{e.message}")
      nil
    end

    # Load the configured stamp/logo and decode it with libvips. If the remote
    # URL serves something that isn't a valid image (HTML error page, redirect
    # body, corrupted bytes, unsupported format), libvips raises
    # "VipsForeignLoad: buffer is not in a known format" which used to crash
    # the signing flow (SubmitFormController#update -> merge_default_values ->
    # CreateStampAttachment). Fall back to the bundled default stamp instead.
    def load_logo_image(submitter)
      io = load_logo(submitter)
      data = io.respond_to?(:read) ? io.read : io.to_s

      if data.blank?
        return Vips::Image.new_from_buffer(PdfIcons.stamp_logo_io.read, '')
      end

      begin
        Vips::Image.new_from_buffer(data, '')
      rescue Vips::Error => e
        Rails.logger.warn("CreateStampAttachment: logo buffer not a valid image (#{e.message}); using default stamp")
        Vips::Image.new_from_buffer(PdfIcons.stamp_logo_io.read, '')
      end
    end
  end
end
