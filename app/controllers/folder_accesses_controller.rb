# frozen_string_literal: true

class FolderAccessesController < ApplicationController
  before_action :load_folder
  before_action :load_folder_access, only: %i[destroy]

  def index
    authorize!(:manage, FolderAccess.new(template_folder: @folder))
    @folder_accesses = @folder.folder_accesses.includes(:user)
    @available_users = available_users_for_sharing
  end

  def create
    authorize!(:manage, FolderAccess.new(template_folder: @folder))

    user_ids = Array(params[:user_ids]).map(&:to_i).reject(&:zero?)

    user_ids.each do |user_id|
      next if @folder.folder_accesses.exists?(user_id:)

      user = current_account.users.find_by(id: user_id)
      next unless user

      @folder.folder_accesses.create!(user_id:)
    end

    respond_to do |format|
      format.html { redirect_to folder_accesses_path(@folder), notice: t('folder_shared_successfully') }
      format.turbo_stream do
        @folder_accesses = @folder.folder_accesses.includes(:user)
        @available_users = available_users_for_sharing
      end
    end
  end

  def destroy
    authorize!(:manage, @folder_access)

    @folder_access.destroy!

    respond_to do |format|
      format.html { redirect_to folder_accesses_path(@folder), notice: t('access_removed_successfully') }
      format.turbo_stream do
        @folder_accesses = @folder.folder_accesses.includes(:user)
        @available_users = available_users_for_sharing
      end
    end
  end

  private

  def load_folder
    @folder = TemplateFolder.find(params[:folder_id])
  end

  def load_folder_access
    @folder_access = @folder.folder_accesses.find(params[:id])
  end

  def available_users_for_sharing
    existing_user_ids = @folder.folder_accesses.pluck(:user_id) + [@folder.author_id]

    current_account.users
                   .where.not(id: existing_user_ids)
                   .where.not(role: :integration)
                   .where(archived_at: nil)
                   .order(:first_name, :last_name)
  end
end
