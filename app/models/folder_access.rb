# frozen_string_literal: true

class FolderAccess < ApplicationRecord
  belongs_to :template_folder
  belongs_to :user, optional: true
end
