# frozen_string_literal: true

class AssignmentRepo < ApplicationRecord
  include AssignmentRepoable
  include StafftoolsSearchable
  include Sortable
  include Searchable

  define_pg_search(columns: %i[id github_repo_id])

  # TODO: remove this enum (dead code)
  enum configuration_state: %i[not_configured configuring configured]

  belongs_to :assignment
  belongs_to :repo_access, optional: true
  belongs_to :user

  has_one :organization, -> { unscope(where: :deleted_at) }, through: :assignment

  validates :assignment, presence: true

  validate :assignment_user_key_uniqueness

  delegate :creator, :starter_code_repo_id, to: :assignment
  delegate :github_user,                    to: :user
  delegate :default_branch, :commits,       to: :github_repository
  delegate :github_team_id,                 to: :repo_access, allow_nil: true

  scope :order_by_created_at, ->(_context = nil) { order(:created_at) }
  scope :order_by_github_login, ->(_context = nil) { joins(:user).order("users.github_login") }

  scope :search_by_github_login, ->(query) { joins(:user).where("users.github_login ILIKE ?", "%#{query}%") }

  def self.sort_modes
    {
      "GitHub login" => :order_by_github_login,
      "Created at" => :order_by_created_at
    }
  end

  def self.search_mode
    :search_by_github_login
  end

  # Public: This method is used for legacy purposes
  # until we can get the transition finally completed
  #
  # NOTE: We used to create one person teams for Assignments,
  # however when the new organization permissions came out
  # https://github.com/blog/2020-improved-organization-permissions
  # we were able to move these students over to being an outside collaborator
  # so when we deleted the AssignmentRepo we would remove the student as well.
  #
  # Returns the User associated with the AssignmentRepo
  alias original_user user
  def user
    original_user || repo_access.user
  end

  private

  # Internal: Validate uniqueness of <user, assignment> key.
  # Only runs the validation on new records.
  #
  def assignment_user_key_uniqueness
    return if persisted?
    return unless AssignmentRepo.find_by(user: user, assignment: assignment)
    errors.add(:assignment, "Should only have one assignment repository for each user-assignment combination")
  end
end
