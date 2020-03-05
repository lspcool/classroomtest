# frozen_string_literal: true

# An optional superclass for github resource models. `GitHubModel` provides a
# consistent hash-based attributes initializer.

class GitHubModel
  # Public: Track each attr_reader added to GitHubModel subclasses.
  def self.attr_reader(*names)
    attr_initializable(*names)
    super
  end

  def self.attr_initializable(*names)
    attr_initializables.concat(names.map(&:to_sym) - [:attributes])
  end

  # Internal: An Array of Hash initializable attributes on this class.
  def self.attr_initializables
    @attr_initializables ||= (superclass <= GitHubModel ? superclass.attr_initializables.dup : [])
  end

  # Internal: The attributes used to initialize this instance.
  attr_reader :attributes, :client, :access_token, :id_attributes

  # Public: Create a new instance, optionally providing a `Hash` of
  # `attributes`. Any attributes with the same name as an
  # `attr_reader` will be set as instance variables.
  #
  # client  - The Octokit::Client making the request.
  # id_args - The Interger ids for the resource.
  # options - A Hash of options to pass (optional).
  #
  # rubocop:disable Metrics/AbcSize
  # rubocop:disable Metrics/BlockLength
  # rubocop:disable MethodLength
  # rubocop:disable CyclomaticComplexity
  def initialize(client, id_attributes, **options)
    resource = options.delete(:classroom_resource)

    attributes = {}.tap do |attr|
      attr[:client]        = client
      attr[:access_token]  = client.access_token
      attr[:id_attributes] = id_attributes

      id_attributes.each do |attr_name, attr_value|
        attr[attr_name] = attr_value
      end

      # Get all of the attributes, set their attr_reader
      # and set their value.
      github_attributes.each do |gh_attr|
        self.class.class_eval { attr_reader gh_attr.to_sym }
        attr[gh_attr.to_sym] = github_response(client, id_attributes.values.compact, options).send(gh_attr)
      end

      local_cached_attributes.each do |gh_attr|
        define_singleton_method(gh_attr) do |use_cache: true|
          field_name = "github_#{gh_attr}".to_sym

          no_cache_options = options.dup
          no_cache_options[:headers] = GitHub::APIHeaders.no_cache_no_store
          cached_value = resource.send(field_name)

          return cached_value if use_cache && cached_value

          api_response = github_response(client, id_attributes.values.compact, no_cache_options)

          local_cached_attributes.each do |attribute|
            resource.assign_attributes("github_#{attribute}" => api_response.send(attribute))
          end

          resource.save if resource.changed?

          resource.send(field_name)
        end
      end

      remove_instance_variable("@response") if defined?(@response)
    end

    update(attributes || {})

    # Create our *_no_cache methods for each GitHubModel
    set_github_no_cache_methods(client, id_attributes.values.compact)

    after_initialize if respond_to? :after_initialize
  end
  # rubocop:enable MethodLength
  # rubocop:enable Metrics/BlockLength
  # rubocop:enable Metrics/AbcSize
  # rubocop:enable CyclomaticComplexity

  # Internal: Update this instance's attribute instance variables with
  # new values.
  #
  # attributes - A Symbol-keyed Hash of new attribute values.
  #
  # Returns self.
  def update(attributes)
    (@attributes ||= {}).merge! attributes

    (self.class.attr_initializables & attributes.keys).each do |name|
      instance_variable_set :"@#{name}", attributes[name]
    end

    self
  end

  # Public: Run an non cached API request to make sure we get something back
  #
  # Returns true if the resource is found, otherwise false.
  def on_github?
    response = github_client_request(
      client,
      id_attributes.values.compact,
      headers: GitHub::APIHeaders.no_cache_no_store
    )
    response ||= github_classroom_request(
      id_attributes.values.compact,
      headers: GitHub::APIHeaders.no_cache_no_store
    )
    response.present?
  end

  private

  # TODO: We can kill these once we're fully migrated to the local DB cache.

  # Internal: Define specified *_no_cache methods.
  #
  # client  - The Octokit::Client making the request.
  # id_args - The Interger ids for the resource.
  #
  # Returns an Sawyer::Resource or a Null:GitHubObject
  def set_github_no_cache_methods(client, id_args)
    github_attributes.each do |gh_no_cache_attr|
      define_singleton_method("#{gh_no_cache_attr}_no_cache") do
        response = github_client_request(client, id_args, headers: GitHub::APIHeaders.no_cache_no_store)
        response ||= github_classroom_request(id_args, headers: GitHub::APIHeaders.no_cache_no_store)
        response.present? ? response.send(gh_no_cache_attr) : null_github_object.send(gh_no_cache_attr)
      end
    end
  end

  # Internal: Return a GitHub API Response for an resource.
  #
  # client  - The Octokit::Client making the request.
  # id_args - The Interger ids for the resource.
  # options - A Hash of options to pass (optional).
  #
  # Returns an Sawyer::Resource or a Null:GitHubObject.
  def github_response(client, id_args, **options)
    return @response if defined?(@response)
    @response = github_client_request(client, id_args, options) || github_classroom_request(id_args, options)
    @response ||= null_github_object
  end

  # Internal: Make a GitHub API request for a resource.
  #
  # client  - The Octokit::Client making the request.
  # id_args - The Interger ids for the resource.
  # options - A Hash of options to pass (optional).
  #
  # Returns a Sawyer::Resource or raises and error.
  def github_client_request(client, id_args, **options)
    GitHub::Errors.with_error_handling { client.send(github_type, *id_args, options) }
  rescue GitHub::Error
    nil
  end

  # Internal: Make a GitHub API request for a resource
  #
  # id_args - The Interger ids for the resource.
  # options - A Hash of options to pass (optional).
  #
  # Returns a Sawyer::Resource or nil if an error occurred.
  def github_classroom_request(id_args, **options)
    GitHub::Errors.with_error_handling do
      GitHubClassroom.github_client(auto_paginate: true).send(github_type, *id_args, options)
    end
  rescue GitHub::Error
    nil
  end

  # Internal: Get the resource type for the model.
  #
  # Example:
  #
  #   GitHubUser -> :user
  #
  # Returns a Symbol.
  def github_type
    self.class.to_s.underscore.gsub(/github_/, "").to_sym
  end

  # Internal: Determin the appropriate NullGitHubObject
  # for the GitHubResource.
  #
  # Returns a NullGitHubObject for the class.
  def null_github_object
    @null_github_object ||= Object.const_get("Null#{self.class}").new
  end
end
