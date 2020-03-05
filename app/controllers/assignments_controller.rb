# frozen_string_literal: true

class AssignmentsController < ApplicationController
  include OrganizationAuthorization
  include StarterCode

  before_action :set_assignment, except: %i[new create]
  before_action :set_list_type,      only: %i[show]
  before_action :set_filter_options, only: %i[show]
  before_action :set_unlinked_users, only: %i[show]

  def new
    @assignment = Assignment.new
  end

  def create
    @assignment = Assignment.new(new_assignment_params)

    @assignment.build_assignment_invitation

    if @assignment.save
      @assignment.deadline&.create_job

      send_create_assignment_statsd_events
      flash[:success] = "\"#{@assignment.title}\" has been created!"
      redirect_to organization_assignment_path(@organization, @assignment)
    else
      render :new
    end
  end

  # rubocop:disable MethodLength
  # rubocop:disable AbcSize
  def show
    # TODO: split into two actions/views (on whether a roster_entry is present or not)
    if @list_type == :assignment_repos
      @assignment_repos = @assignment.assignment_repos
        .filter_by_search(@query)
        .order_by_sort_mode(@current_sort_mode)
        .order(:id)
        .page(params[:page])

    elsif @list_type == :roster_entries
      @roster_entries = @organization.roster.roster_entries
        .filter_by_search(@query)
        .page(params[:students_page])
        .order_for_view(@assignment)
        .order_by_sort_mode(@current_sort_mode, assignment: @assignment)
        .order(:id)

      @unlinked_user_repos = AssignmentRepo
        .where(assignment: @assignment, user: @unlinked_users)
        .order(:id)
        .page(params[:unlinked_accounts_page])
    end

    respond_to do |format|
      format.html
      format.js do
        render "assignments/filter_repos.js.erb", format: :js
      end
    end
  end
  # rubocop:enable AbcSize
  # rubocop:enable MethodLength

  def edit; end

  def update
    result = Assignment::Editor.perform(assignment: @assignment, options: update_assignment_params.to_h)
    if result.success?
      flash[:success] = "Assignment \"#{@assignment.title}\" is being updated"
      redirect_to organization_assignment_path(@organization, @assignment)
    else
      @assignment.reload if @assignment.slug.blank?
      render :edit
    end
  end

  def destroy
    if @assignment.update_attributes(deleted_at: Time.zone.now)
      DestroyResourceJob.perform_later(@assignment)

      GitHubClassroom.statsd.increment("exercise.destroy")

      flash[:success] = "\"#{@assignment.title}\" is being deleted"
      redirect_to @organization
    else
      render :edit
    end
  end

  def assistant
    code_param = current_user.api_token
    url_param = CGI.escape(organization_assignment_url)

    redirect_to "x-github-classroom://?assignment_url=#{url_param}&code=#{code_param}"
  end

  def toggle_invitations
    @assignment.update(invitations_enabled: params[:invitations_enabled])
    respond_to do |format|
      format.js
      format.html { redirect_to organization_assignment_path(@organization, @assignment) }
    end
  end

  private

  def new_assignment_params
    params
      .require(:assignment)
      .permit(:title, :slug, :visibility, :students_are_repo_admins, :invitations_enabled, :template_repos_enabled)
      .merge(creator: current_user,
             organization: @organization,
             starter_code_repo_id: starter_code_repo_id_param,
             deadline: deadline_param)
  end

  # An unlinked user in the context of an assignment is a user who:
  # - Is a user on the assignment
  # - Is not on the organization roster
  def set_unlinked_users
    return unless @organization.roster

    assignment_users = @assignment.users

    roster_entry_user_ids = @organization.roster.roster_entries.pluck(:user_id)
    roster_entry_users = User.where(id: roster_entry_user_ids)

    @unlinked_users = assignment_users - roster_entry_users
  end

  def set_assignment
    @assignment = @organization.assignments.includes(:assignment_invitation).find_by!(slug: params[:id])
  end

  def set_list_type
    @list_type = @organization.roster ? :roster_entries : :assignment_repos
  end

  def set_filter_options
    @assignment_sort_modes = @list_type == :roster_entries ? RosterEntry.sort_modes : AssignmentRepo.sort_modes

    @current_sort_mode = params[:sort_by] || @assignment_sort_modes.keys.first
    @query = params[:query]

    @assignment_sort_modes_links = @assignment_sort_modes.keys.map do |mode|
      organization_assignment_path(
        sort_by: mode,
        query: @query
      )
    end
  end

  def deadline_param
    return if params[:assignment][:deadline].blank?

    Deadline::Factory.build_from_string(deadline_at: params[:assignment][:deadline])
  end

  def starter_code_repo_id_param
    if params[:repo_id].present?
      validate_starter_code_repository_id(params[:repo_id])
    else
      starter_code_repository_id(params[:repo_name])
    end
  end

  # rubocop:disable MethodLength
  def update_assignment_params
    params
      .require(:assignment)
      .permit(
        :title,
        :slug,
        :visibility,
        :students_are_repo_admins,
        :deadline, :invitations_enabled,
        :template_repos_enabled
      )
      .merge(starter_code_repo_id: starter_code_repo_id_param)
  end

  def send_create_assignment_statsd_events
    GitHubClassroom.statsd.increment("exercise.create")
    GitHubClassroom.statsd.increment("deadline.create") if @assignment.deadline
  end
end
