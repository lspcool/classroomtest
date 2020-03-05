# frozen_string_literal: true

module Orgs
  class LtiConfigurationsController < Orgs::Controller
    before_action :ensure_current_lti_configuration, except: %i[info new create]
    before_action :ensure_no_google_classroom, only: %i[new create]
    before_action :ensure_no_roster, only: %i[new create]
    before_action :ensure_lms_type, only: %i[create]

    skip_before_action :authenticate_user!, only: :autoconfigure
    skip_before_action :ensure_current_organization_visible_to_current_user, only: :autoconfigure

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def create
      lti_configuration = LtiConfiguration.create(
        organization: current_organization,
        lms_type: lti_configuration_params[:lms_type],
        consumer_key: SecureRandom.uuid,
        shared_secret: SecureRandom.uuid
      )

      if lti_configuration.present?
        GitHubClassroom.statsd.increment("lti_configuration.create")
        redirect_to lti_configuration_path(current_organization)
      else
        redirect_to info_lti_configuration_path(current_lti_configuration),
          alert: "There was a problem creating the configuration. Please try again later."
      end
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    def show; end

    def new
      @lti_configuration = LtiConfiguration.new(lms_type: nil)
    end

    def info
      lms_type = params[:lms_type]
      @lti_configuration = LtiConfiguration.new(lms_type: lms_type)
    end

    def destroy
      lms_name = current_lti_configuration.lms_name(default_name: "your learning management system")
      GitHubClassroom.statsd.increment("lti_configuration.destroy")
      current_lti_configuration.destroy!
      redirect_to edit_organization_path(current_organization), alert: "Classroom is now disconnected from #{lms_name}."
    end

    def autoconfigure
      not_found unless current_lti_configuration.supports_autoconfiguration?

      xml_configuration = current_lti_configuration.xml_configuration(auth_lti_launch_url)
      render xml: xml_configuration, status: :ok
    end

    def complete; end

    private

    def current_lti_configuration
      @current_lti_configuration ||= current_organization.lti_configuration
    end
    helper_method :current_lti_configuration

    def ensure_current_lti_configuration
      redirect_to info_lti_configuration_path(current_organization) unless current_lti_configuration
    end

    def lti_configuration_params
      params.require(:lti_configuration).permit(:lms_type)
    end

    def ensure_no_google_classroom
      return unless current_organization.google_course_id
      redirect_to edit_organization_path(current_organization),
        alert: "This classroom is already connected to Google Classroom. Please disconnect from Google Classroom "\
          "before connecting to another learning management system."
    end

    def ensure_no_roster
      return unless current_organization.roster
      redirect_to edit_organization_path(current_organization),
        alert: "We are unable to link your classroom organization to a learning management system "\
          "because a roster already exists. Please delete your current roster and try again."
    end

    def ensure_lms_type
      return if params.dig(:lti_configuration, :lms_type).present?
      redirect_to new_lti_configuration_path(current_organization)
    end
  end
end
