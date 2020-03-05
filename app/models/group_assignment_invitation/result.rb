# frozen_string_literal: true

class GroupAssignmentInvitation
  class Result
    class Error < StandardError; end

    def self.success(group_assignment_repo)
      new(:success, group_assignment_repo: group_assignment_repo)
    end

    def self.failed(error)
      new(:failed, error: error)
    end

    def self.pending
      new(:pending)
    end

    attr_reader :error, :group_assignment_repo, :status

    def initialize(status, group_assignment_repo: nil, error: nil)
      @status = status
      @group_assignment_repo = group_assignment_repo
      @error = error
    end

    def success?
      @status == :success
    end

    def failed?
      @status == :failed
    end

    def pending?
      @status == :pending
    end
  end
end
