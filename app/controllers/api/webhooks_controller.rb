# frozen_string_literal: true

module Api
  class WebhooksController < ApiBaseController
    before_action do
      authorize!(:manage, WebhookUrl)
    end

    # GET /api/webhooks
    def index
      webhooks = paginate(current_account.webhook_urls)

      render json: {
        data: webhooks.map { |w| serialize_webhook(w) },
        pagination: {
          count: webhooks.size,
          next: webhooks.last&.id,
          prev: webhooks.first&.id
        }
      }
    end

    # GET /api/webhooks/:id
    def show
      webhook = current_account.webhook_urls.find(params[:id])

      render json: serialize_webhook(webhook)
    end

    # POST /api/webhooks
    def create
      webhook = current_account.webhook_urls.new(
        url: params[:url],
        events: normalize_events(params[:events]),
        secret: normalize_secret(params[:secret])
      )

      if webhook.save
        render json: serialize_webhook(webhook), status: :created
      else
        render json: { error: webhook.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # PUT /api/webhooks/:id
    def update
      webhook = current_account.webhook_urls.find(params[:id])

      attrs = {}
      attrs[:url] = params[:url] if params.key?(:url)
      attrs[:events] = normalize_events(params[:events]) if params.key?(:events)
      attrs[:secret] = normalize_secret(params[:secret]) if params.key?(:secret)

      if webhook.update(attrs)
        render json: serialize_webhook(webhook)
      else
        render json: { error: webhook.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # DELETE /api/webhooks/:id
    def destroy
      webhook = current_account.webhook_urls.find(params[:id])
      webhook.destroy!

      render json: { message: 'Webhook has been deleted' }
    end

    # POST /api/webhooks/:id/test
    def test
      webhook = current_account.webhook_urls.find(params[:webhook_id])
      submitter = current_account.submitters.where.not(completed_at: nil).order(:id).last

      if submitter.blank?
        return render json: { error: 'No completed submitter found to generate test payload' },
                      status: :unprocessable_entity
      end

      SendTestWebhookRequestJob.perform_async(
        'submitter_id' => submitter.id,
        'event_uuid' => SecureRandom.uuid,
        'webhook_url_id' => webhook.id
      )

      render json: { message: 'Test webhook request has been queued' }
    end

    private

    def serialize_webhook(webhook)
      {
        id: webhook.id,
        url: webhook.url,
        events: webhook.events,
        secret: webhook.secret,
        created_at: webhook.created_at,
        updated_at: webhook.updated_at
      }
    end

    def normalize_events(events)
      return WebhookUrl::EVENTS if events.blank?

      Array.wrap(events).select { |e| WebhookUrl::EVENTS.include?(e) }
    end

    def normalize_secret(secret)
      return {} if secret.blank?

      if secret.is_a?(Hash) || (secret.respond_to?(:to_unsafe_h) && (secret = secret.to_unsafe_h))
        secret.to_h.slice(*secret.keys.first(1)).compact_blank.transform_keys(&:to_s)
      else
        {}
      end
    end
  end
end
