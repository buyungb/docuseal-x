# frozen_string_literal: true

class TemplateAccessesController < ApplicationController
  load_and_authorize_resource :template
  before_action :load_template_access, only: %i[destroy]

  def index
    @template_accesses = @template.template_accesses.includes(:user)
    @available_users = available_users_for_sharing
  end

  def create
    authorize!(:manage, TemplateAccess.new(template: @template))

    user_ids = Array(params[:user_ids]).map(&:to_i).reject(&:zero?)

    user_ids.each do |user_id|
      next if @template.template_accesses.exists?(user_id:)

      user = current_account.users.find_by(id: user_id)
      next unless user

      @template.template_accesses.create!(user_id:)
    end

    respond_to do |format|
      format.html { redirect_to template_accesses_path(@template), notice: t('template_shared_successfully') }
      format.turbo_stream do
        @template_accesses = @template.template_accesses.includes(:user)
        @available_users = available_users_for_sharing
      end
    end
  end

  def destroy
    authorize!(:manage, @template_access)

    @template_access.destroy!

    respond_to do |format|
      format.html { redirect_to template_accesses_path(@template), notice: t('access_removed_successfully') }
      format.turbo_stream do
        @template_accesses = @template.template_accesses.includes(:user)
        @available_users = available_users_for_sharing
      end
    end
  end

  private

  def load_template_access
    @template_access = @template.template_accesses.find(params[:id])
  end

  def available_users_for_sharing
    existing_user_ids = @template.template_accesses.pluck(:user_id) + [@template.author_id]

    current_account.users
                   .where.not(id: existing_user_ids)
                   .where.not(role: :integration)
                   .where(archived_at: nil)
                   .order(:first_name, :last_name)
  end
end
