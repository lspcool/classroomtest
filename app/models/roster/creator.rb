# frozen_string_literal: true

class Roster
  class Creator
    class Result
      class Error < StandardError; end

      def self.success(roster)
        new(:success, roster: roster)
      end

      def self.failed(roster, error)
        new(:failed, roster: roster, error: error)
      end

      attr_reader :error, :roster

      def initialize(status, roster: nil, error: nil)
        @status = status
        @roster = roster
        @error  = error
      end

      def success?
        @status == :success
      end

      def failed?
        @status == :failed
      end
    end

    DEFAULT_IDENTIFIER_NAME = "Identifiers"

    include DuplicateRosterEntries

    # Public: Create a Roster for an Organiation.
    #
    # organization    - The Organization the Roster will belong to.
    # identifier_name - The name of the identifiers for the Roster.
    # options         - The Hash of options.
    #
    # Examples
    #
    #   Roster::Creator.perform(
    #     organization: current_organization,
    #     identifier_name: "Email",
    #     options
    #   )
    #
    # Returns an Roster::Creator::Result.
    def self.perform(organization:, **options)
      new(organization: organization, **options).perform
    end

    def initialize(organization:, **options)
      @organization    = organization
      @options         = options
      @roster = Roster.new(identifier_name: DEFAULT_IDENTIFIER_NAME)
    end

    # Internal: Create create a Roster.
    #
    def perform
      ensure_organization_does_not_have_roster!

      ActiveRecord::Base.transaction do
        lms_ids = @options[:lms_user_ids] || []
        add_identifiers_to_roster(@options[:identifiers], lms_ids: lms_ids) if @options.key?(:identifiers)

        @roster.save!
        @organization.update_attributes!(roster: @roster)
      end

      Result.success(@roster)
    rescue Result::Error, ActiveRecord::ActiveRecordError => err
      Result.failed(@roster, err.message)
    end

    private

    def add_identifiers_to_roster(raw_identifiers_string, lms_ids: [])
      identifiers = raw_identifiers_string.split("\r\n").reject(&:blank?)
      identifiers = Roster.add_suffix_to_duplicates(identifiers: identifiers)

      identifiers.zip(lms_ids).each do |identifier, lms_user_id|
        @roster.roster_entries << RosterEntry.new(identifier: identifier, lms_user_id: lms_user_id)
      end
    end

    def ensure_organization_does_not_have_roster!
      raise Result::Error, "This organization already has a roster" unless @organization.roster.nil?
    end
  end
end
