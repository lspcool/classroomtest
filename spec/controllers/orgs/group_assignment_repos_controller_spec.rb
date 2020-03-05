# frozen_string_literal: true

require "rails_helper"

RSpec.describe Orgs::GroupAssignmentReposController, type: :controller do
  let(:user)         { classroom_teacher }
  let(:organization) { classroom_org     }
  let(:student)      { classroom_student }

  let(:grouping)     { create(:grouping, organization: organization) }
  let(:github_team_id) { 3_284_880 }
  let(:group) { create(:group, grouping: grouping, github_team_id: github_team_id) }
  let(:group_assignment) do
    create(
      :group_assignment,
      grouping: grouping,
      title: "Learn JavaScript",
      organization: organization,
      public_repo: true,
      starter_code_repo_id: 1_062_897
    )
  end
  let(:group_assignment_repo) do
    create(
      :group_assignment_repo,
      group_assignment: group_assignment,
      group: group,
      organization: organization,
      github_repo_id: 42
    )
  end

  before(:each) do
    sign_in_as(user)
  end

  after do
    GroupAssignmentRepo.destroy_all
  end

  describe "GET #show", :vcr do
    context "as an unauthorized user" do
      before do
        sign_out
      end

      it "returns a 404" do
        params = {
          id: group_assignment_repo.id,
          organization_id: organization.slug,
          group_assignment_id: group_assignment.slug
        }

        get :show, params: params
        expect(response).to redirect_to(login_path)
      end
    end

    context "as an authorized user" do
      context "with properly scoped resource" do
        before do
          params = {
            id: group_assignment_repo.id,
            organization_id: organization.slug,
            group_assignment_id: group_assignment.slug
          }

          get :show, params: params
        end

        it "succeeds" do
          expect(response).to have_http_status(200)
        end

        it "sets the GroupAssignmentRepo" do
          expect(assigns[:group_assignment_repo].id).to eq(group_assignment_repo.id)
        end
      end

      context "with improperly scoped resource" do
        it "returns not found" do
          params = {
            id: group_assignment_repo.id,
            organization_id: organization.slug,
            group_assignment_id: "#{group_assignment.slug}-a"
          }

          get :show, params: params

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
