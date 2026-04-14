# frozen_string_literal: true

module Api
  class UsersController < ApiBaseController
    before_action do
      authorize!(:manage, User) unless action_name == 'show'
    end

    # GET /api/user - Show current authenticated user
    # GET /api/users - List all users in the account
    # GET /api/users/:id - Show a specific user
    def show
      if params[:id].present?
        authorize!(:read, User)
        user = current_account.users.active.find(params[:id])
        render json: serialize_user(user)
      else
        render json: serialize_user(current_user)
      end
    end

    def index
      authorize!(:read, User)
      users = current_account.users.active.where.not(role: 'integration').order(id: :desc)
      render json: users.map { |u| serialize_user(u) }
    end

    # POST /api/users
    def create
      user = current_account.users.new(user_create_params)
      user.password = SecureRandom.hex if user.password.blank?
      user.role = User::ADMIN_ROLE unless User::ROLES.include?(user.role)

      if user.save
        render json: serialize_user(user, with_api_key: true), status: :created
      else
        render json: { error: user.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # PUT /api/users/:id
    def update
      user = current_account.users.active.find(params[:id])
      attrs = user_update_params.compact_blank

      if user.update(attrs)
        render json: serialize_user(user)
      else
        render json: { error: user.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # DELETE /api/users/:id
    def destroy
      user = current_account.users.active.find(params[:id])

      if user.id == current_user.id
        return render json: { error: 'Cannot delete your own account' }, status: :unprocessable_entity
      end

      user.update!(archived_at: Time.current)
      render json: { message: 'User has been removed' }
    end

    # POST /api/users/:id/api_key - Regenerate API key for a user
    def api_key
      user = current_account.users.active.find(params[:id])

      token = user.access_token
      token.token = SecureRandom.base58(AccessToken::TOKEN_LENGTH)
      token.save!

      render json: {
        id: user.id,
        email: user.email,
        api_key: token.token
      }
    end

    # GET /api/users/:id/api_key - Get API key for a user
    def show_api_key
      user = current_account.users.active.find(params[:id])
      token = user.access_token

      render json: {
        id: user.id,
        email: user.email,
        api_key: token.token
      }
    end

    private

    def serialize_user(user, with_api_key: false)
      data = {
        id: user.id,
        email: user.email,
        first_name: user.first_name,
        last_name: user.last_name,
        role: user.role,
        created_at: user.created_at,
        updated_at: user.updated_at
      }

      data[:api_key] = user.access_token.token if with_api_key

      data
    end

    def user_create_params
      params.permit(:email, :first_name, :last_name, :password, :role)
    end

    def user_update_params
      params.permit(:email, :first_name, :last_name, :password, :role)
    end
  end
end
