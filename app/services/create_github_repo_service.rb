# frozen_string_literal: true

class CreateGitHubRepoService
  attr_reader :exercise, :stats_sender
  delegate :assignment, :collaborator, :organization, :invite_status, to: :exercise

  def initialize(assignment, collaborator)
    @exercise = Exercise.build(assignment, collaborator)
    @stats_sender = StatsSender.new(@exercise)
  end

  # rubocop:disable MethodLength
  # rubocop:disable AbcSize
  def perform
    start = Time.zone.now
    invite_status.creating_repo!
    Broadcaster.call(exercise, :create_repo, :text)

    verify_organization_has_private_repos_available!

    github_repository =
      if exercise.use_template_repos?
        create_github_repository_from_template!
      else
        create_github_repository!
      end

    assignment_repo = create_assignment_repo!(github_repository)

    add_collaborator_to_github_repository!(github_repository)

    if assignment.use_importer?
      push_starter_code!(github_repository)
      invite_status.importing_starter_code!
      Broadcaster.call(exercise, :importing_starter_code, :text, assignment_repo&.github_repository&.html_url)
      stats_sender.report_with_exercise_prefix(:import_started)
    else
      invite_status.completed!
      Broadcaster.call(exercise, :repository_creation_complete, :text)
    end

    stats_sender.timing(start)
    stats_sender.report_default(:success)
    Result.success(assignment_repo, exercise)
  rescue Result::Error => error
    repo_id = assignment_repo&.github_repo_id || github_repository&.id
    delete_github_repository(repo_id)
    Result.failed(error.message, exercise)
  end
  # rubocop:enable MethodLength
  # rubocop:enable AbcSize

  # Public: Creates a new GitHub Repository based on assignment name and privacy details.
  #
  # Returns created GitHubRepository object or raises a Result::Error on failure.
  def create_github_repository!
    options = {
      private: assignment.private?,
      description: "#{exercise.repo_name} created by GitHub Classroom"
    }

    organization.github_organization.create_repository(exercise.repo_name, options)
  rescue GitHub::Error => error
    raise Result::Error.new errors(:repository_creation_failed), error.message
  end

  # Public: Clone the GitHub template repository for the Assignment.
  #
  # Returns an Integer ID or raises a Result::Error
  # rubocop:disable Metrics/MethodLength
  # rubocop:disable Metrics/AbcSize
  def create_github_repository_from_template!
    stats_sender.report_with_exercise_prefix(:import_with_templates_started)

    options = repo_from_template_options

    github_repository = organization.github_organization.create_repository_from_template(
      assignment.starter_code_repo_id,
      exercise.repo_name,
      options
    )

    stats_sender.report_with_exercise_prefix(:import_with_templates_success)
    github_repository
  rescue GitHub::NotFound => error
    raise Result::Error.new errors(:template_repository_not_found), error.message
  rescue GitHub::Error => error
    report_template_error_to_failbot(error, options)
    raise Result::Error.new errors(:template_repository_creation_failed), error.message
  end
  # rubocop:enable Metrics/MethodLength
  # rubocop:enable Metrics/AbcSize

  # Public: Creates a new AssignmentRepo/GroupAssignmentRepo object
  #         with github_repository id and relay id.
  #
  # github_repository - GitHubRepository object of the newly created repo.
  #
  # Returns the created AssignmentRepo/GroupAssignmentRepo object
  # or raises a Result::Error on failure
  def create_assignment_repo!(github_repository)
    assignment_repo_attrs = {
      github_repo_id: github_repository.id
    }
    assignment_repo_attrs[exercise.humanize] = exercise.collaborator
    assignment_repo = exercise.repos.build(assignment_repo_attrs)
    assignment_repo.save!
    assignment_repo
  rescue ActiveRecord::RecordInvalid => error
    raise Result::Error.new errors(:default), error.message
  end

  def delete_github_repository(github_repo_id)
    return true if github_repo_id.nil?
    organization.github_organization.delete_repository(github_repo_id)
  rescue GitHub::Error
    true
  end

  # Public: Push starter code to the newly created GitHub
  #         repository.
  #
  # assignment_repository - GitHubRepository in which starter code is to be imported.
  #
  # Returns true of raises a Result::Error.
  def push_starter_code!(assignment_repository)
    client = assignment.creator.github_client
    starter_code_repo_id = assignment.starter_code_repo_id
    starter_code_repository = GitHubRepository.new(client, starter_code_repo_id)

    assignment_repository.get_starter_code_from(starter_code_repository)
  rescue GitHub::Error => error
    raise Result::Error.new errors(:starter_code_import_failed), error.message
  end

  # Public: Ensure that we can make a private repository on GitHub.
  #
  # Returns True or raises a Result::Error with a helpful message.
  def verify_organization_has_private_repos_available!
    return unless assignment.private?
    begin
      github_organization_plan = organization.plan
    rescue GitHub::Error => error
      raise Result::Error, error.message
    end

    owned_private_repos = github_organization_plan[:owned_private_repos]
    private_repos       = github_organization_plan[:private_repos]

    return true if owned_private_repos < private_repos
    raise Result::Error, errors(:private_repos_not_available, github_organization_plan)
  end
  # rubocop:enable AbcSize

  # Public: Add user/team to the GitHubRepository based on the type of assignment.
  #         Calls #add_user_to_github_repository! if it is an Assignment.
  #         Calls #add_group_to_github_repository! if it is a GroupAssignment.
  #
  # github_repository - GitHubRepository in which we need to add collaborator.
  #
  # Returns true if collaborator added or raises a Result::Error.
  def add_collaborator_to_github_repository!(github_repository)
    if exercise.user?
      add_user_to_github_repository!(github_repository)
    else
      add_group_to_github_repository!(github_repository)
    end
  rescue GitHub::Error => error
    raise Result::Error.new errors(:collaborator_addition_failed), error.message
  end

  # Maps the type of error to a Datadog error
  #
  # rubocop:disable MethodLength, AbcSize
  def report_error(err)
    case err
    when /^#{errors(:repository_creation_failed)}/
      stats_sender.report_with_exercise_prefix(:repository_creation_failed)
    when /^#{errors(:template_repository_creation_failed)}/
      stats_sender.report_with_exercise_prefix(:template_repository_creation_failed)
    when /^#{errors(:template_repository_not_found)}/
      stats_sender.report_with_exercise_prefix(:template_repository_not_found)
    when /^#{errors(:collaborator_addition_failed)}/
      stats_sender.report_with_exercise_prefix(:collaborator_addition_failed)
    when /^#{errors(:starter_code_import_failed)}/
      stats_sender.report_with_exercise_prefix(:starter_code_import_failed)
    else
      stats_sender.report_default(:failure)
    end
  end
  # rubocop:enable MethodLength

  private

  # Internal: Creates a new team on GitHub and adds it to the repository.
  #
  # github_repository - GitHubRepository in which we need to add the team.
  #
  # Returns true if collaborator added or raises a GitHub::Error.
  def add_group_to_github_repository!(github_repository)
    github_team = GitHubTeam.new(organization.github_client, exercise.collaborator.github_team_id)
    github_team.add_team_repository(github_repository.full_name, repository_permissions)
  end

  # Internal: Creates a new invitation for the GitHubRepository and then accepts it on behalf
  #           of the user.
  #
  # github_repository - GitHubRepository in which we need to add the user.
  #
  # Returns true if collaborator added or raises a GitHub::Error.
  def add_user_to_github_repository!(github_repository)
    invitation = github_repository.invite(exercise.slug, repository_permissions)
    exercise.collaborator.github_user.accept_repository_invitation(invitation.id) if invitation.present?
  end

  def repository_permissions
    {}.tap do |options|
      options[:permission] = exercise.admin? ? "admin" : "push"
    end
  end

  def repo_from_template_options
    {
      private: assignment.private?,
      description: "#{exercise.repo_name} created by GitHub Classroom",
      owner: organization.github_organization.login,
      include_all_branches: true
    }
  end

  # rubocop:disable MethodLength
  def report_template_error_to_failbot(error, options)
    error_context = {}.tap do |e|
      e[:user] = collaborator.id if collaborator.is_a? User
      e[:github_team_id] = collaborator.github_team_id if collaborator.is_a? Group
      e[:starter_code_repo_id] = assignment.starter_code_repo_id
      e[:organization] = organization.id
      e[:new_repo_name] = exercise.repo_name
      e[:params] = options
    end
    Failbot.report!(
      error,
      error_context
    )
  end

  # Internal: Method for error messages, modifies error messages based on the type of assignment.
  #
  # error_message - A symbol for getting the  appropriate error message.
  # rubocop:disable CyclomaticComplexity
  def errors(error_message, options = {})
    case error_message
    when :repository_creation_failed
      "GitHub repository could not be created, please try again."
    when :template_repository_creation_failed
      "GitHub repository could not be created from template, please try again."
    when :template_repository_not_found
      "Starter code template repository was not found. The repository might be deleted, or the organization that "\
        "owns the repository has restrictions on third-party access."
    when :starter_code_import_failed
      "We were not able to import you the starter code to your #{exercise.assignment_type.humanize}, please try again."
    when :collaborator_addition_failed
      "We were not able to add the #{exercise.humanize} to the #{exercise.assignment_type.humanize}, please try again."
    when :private_repos_not_available
      <<-ERROR
      Cannot make this private assignment, your limit of #{options[:private_repos]}
       #{'repository'.pluralize(options[:private_repos])} has been reached. You can request
       a larger plan for free at https://education.github.com/discount
       ERROR
    else
      "#{exercise.assignment_type.humanize} could not be created, please try again."
    end
  end
  # rubocop:enable MethodLength
end
