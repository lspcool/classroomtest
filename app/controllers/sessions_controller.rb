# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :authenticate_user!

  depends_on :lti

  def new
    scopes = session[:required_scopes] || default_required_scopes
    scope_param = { scope: scopes }.to_param
    redirect_to "/auth/github?#{scope_param}"
  end

  def default_required_scopes
    GitHubClassroom::Scopes::TEACHER.join(",")
  end

  def create
    auth_hash = request.env["omniauth.auth"]
    user      = User.find_by_auth_hash(auth_hash) || User.new

    user.assign_from_auth_hash(auth_hash)

    session[:user_id] = user.id

    url = session[:pre_login_destination] || organizations_path

    session[:current_scopes] = user.github_client_scopes

    redirect_to url
  end

  def destroy
    log_out
  end

  def failure
    if params[:strategy] == "lti"
      return redirect_to auth_lti_failure_path(request.parameters) if params[:strategy] == "lti"
    end
    redirect_to root_path, alert: "There was a problem authenticating with GitHub, please try again."
  end

  private

  def allow_in_iframe
    response.headers.delete "X-Frame-Options"
  end
end
