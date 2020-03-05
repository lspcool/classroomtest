# frozen_string_literal: true

class OrganizationsController < Orgs::Controller
  before_action :ensure_team_management_flipper_is_enabled, only: [:show_groupings]

  before_action :authorize_organization_addition,     only: [:create]
  before_action :set_users_github_organizations,      only: %i[index new create]
  before_action :add_current_user_to_organizations,   only: [:index]
  before_action :paginate_users_github_organizations, only: %i[new create]
  before_action :verify_user_belongs_to_organization, only: [:remove_user]
  before_action :set_filter_options,                  only: %i[search index]
  before_action :set_filtered_organizations,          only: %i[search index]

  skip_before_action :ensure_current_organization,                         only: %i[index new create search]
  skip_before_action :ensure_current_organization_visible_to_current_user, only: %i[index new create search]

  def index; end

  def github_access_management_url
    github_url = GitHubClassroom.github_url
    github_client_id = Rails.application.secrets.github_client_id
    "#{github_url}/settings/connections/applications/#{github_client_id}/?return_to=classroom"
  end
  helper_method :github_access_management_url

  def new
    @organization = Organization.new
  end

  # rubocop:disable MethodLength
  def create
    result = Organization::Creator.perform(
      github_id: new_organization_params[:github_id],
      users: new_organization_params[:users]
    )

    if result.success?
      @organization = result.organization
      redirect_to setup_organization_path(@organization)
    else
      flash[:error] = result.error
      redirect_to new_organization_path
    end
  end
  # rubocop:enable MethodLength

  def show
    # sort assignments by title
    @assignments = Kaminari
      .paginate_array(current_organization.all_assignments(with_invitations: true)
      .sort_by(&:title))
      .page(params[:page])
  end

  def edit; end

  def invitation; end

  def show_groupings
    @groupings = current_organization.groupings
  end

  # rubocop:disable Metrics/MethodLength
  # rubocop:disable Metrics/AbcSize
  def update
    result = Organization::Editor.perform(organization: current_organization, options: update_organization_params.to_h)

    respond_to do |format|
      format.html do
        if result.success?
          flash[:success] = "Successfully updated \"#{current_organization.title}\"!"
          redirect_to current_organization
        else
          current_organization.reload
          render :edit
        end
      end
      format.js do
        set_filter_options
        set_filtered_organizations
        render "organizations/archive.js.erb", format: :js
      end
    end
  end
  # rubocop:enable Metrics/MethodLength
  # rubocop:enable Metrics/AbcSize

  def destroy
    if current_organization.update_attributes(deleted_at: Time.zone.now)
      DestroyResourceJob.perform_later(current_organization)

      flash[:success] = "Your classroom, @#{current_organization.title} is being deleted"
      redirect_to organizations_path
    else
      render :edit
    end
  end

  def remove_user
    if current_organization.one_owner_remains?
      flash[:error] = "The user can not be removed from the classroom"
    else
      TransferAssignmentsService.new(current_organization, @removed_user).transfer
      current_organization.users.delete(@removed_user)
      flash[:success] = "The user has been removed from the classroom"
    end

    redirect_to settings_invitations_organization_path
  end

  def new_assignment; end

  def link_lms; end

  def invite; end

  def setup; end

  def setup_organization
    if current_organization.update_attributes(update_organization_params)
      redirect_to invite_organization_path(current_organization)
    else
      render :setup
    end
  end

  def search; end

  private

  def authorize_organization_addition
    new_github_organization = github_organization_from_params

    return if new_github_organization.admin?(current_user_login)
    raise NotAuthorized, "You are not permitted to add this organization as a classroom"
  end

  def github_organization_from_params
    @github_organization_from_params ||= GitHubOrganization.new(
      current_user.github_client,
      params[:organization][:github_id].to_i
    )
  end

  def new_organization_params
    params.require(:organization).permit(:github_id).merge(users: [current_user])
  end

  def set_users_github_organizations
    @users_github_organizations = current_user.github_user.organization_memberships.map do |membership|
      {
        github_id:   membership.organization.id,
        login:       membership.organization.login,
        owner_login: membership.user.login,
        role:        membership.role
      }
    end
  end

  # rubocop:disable Metrics/AbcSize
  # rubocop:disable Metrics/MethodLength
  def set_filter_options
    @sort_modes = Organization.sort_modes
    @view_modes = Organization.view_modes

    @current_sort_mode = if @sort_modes.keys.include?(params[:sort_by])
                           params[:sort_by]
                         else
                           @sort_modes.keys.first
                         end

    @current_view_mode = if @view_modes.keys.include?(params[:view])
                           params[:view]
                         else
                           @view_modes.keys.first
                         end

    @query = params[:query]
  end
  # rubocop:enable Metrics/AbcSize
  # rubocop:enable Metrics/MethodLength

  # rubocop:disable Metrics/MethodLength
  def set_filtered_organizations
    scope = current_user.organizations.includes(:assignments, :group_assignments).filter_by_search(@query)

    scope = case @current_view_mode
            when "Archived" then scope.archived
            when "Active" then scope.not_archived
            else scope
            end

    @organizations = scope
      .order_by_sort_mode(@current_sort_mode)
      .order(:id)
      .page(params[:page])
      .per(12)
  end
  # rubocop:enable Metrics/MethodLength

  # Check if the current user has any organizations with admin privilege,
  # if so add the user to the corresponding classroom automatically.
  def add_current_user_to_organizations
    @users_github_organizations.each do |github_org|
      user_classrooms = Organization.includes(:users).where(github_id: github_org[:github_id])

      # Iterate over each classroom associate with this github organization
      user_classrooms.map do |classroom|
        create_user_organization_access(classroom) unless classroom.users.include?(current_user)
      end
    end
  end

  def create_user_organization_access(organization)
    github_org = GitHubOrganization.new(current_user.github_client, organization.github_id)
    return unless github_org.admin?(current_user_login)
    organization.users << current_user
  end

  def paginate_users_github_organizations
    @users_github_organizations = Kaminari.paginate_array(@users_github_organizations).page(params[:page]).per(24)
  end

  def update_organization_params
    params
      .require(:organization)
      .permit(:title, :archived)
  end

  def verify_user_belongs_to_organization
    @removed_user = User.find(params[:user_id])
    not_found unless current_organization.users.map(&:id).include?(@removed_user.id)
  end

  def current_user_login
    @current_user_login ||= current_user.github_user.login(use_cache: false)
  end
end
