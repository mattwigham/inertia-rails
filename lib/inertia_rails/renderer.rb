require 'net/http'
require 'json'
require_relative "inertia_rails"

module InertiaRails
  class Renderer
    attr_reader(
      :component,
      :configuration,
      :controller,
      :props,
      :view_data,
    )

    def initialize(component, controller, request, response, render_method, props: nil, view_data: nil, deep_merge: nil)
      @controller = controller
      @configuration = controller.__send__(:inertia_configuration)
      @component = resolve_component(component)
      @request = request
      @response = response
      @render_method = render_method
      @props = props || controller.__send__(:inertia_view_assigns)
      @view_data = view_data || {}
      @deep_merge = !deep_merge.nil? ? deep_merge : configuration.deep_merge_shared_data
    end

    def render
      if @response.headers["Vary"].blank?
        @response.headers["Vary"] = 'X-Inertia'
      else
        @response.headers["Vary"] = "#{@response.headers["Vary"]}, X-Inertia"
      end
      if @request.headers['X-Inertia']
        @response.set_header('X-Inertia', 'true')
        @render_method.call json: page, status: @response.status, content_type: Mime[:json]
      else
        return render_ssr if configuration.ssr_enabled rescue nil
        @render_method.call template: 'inertia', layout: layout, locals: view_data.merge(page: page)
      end
    end

    private

    def render_ssr
      uri = URI("#{configuration.ssr_url}/render")
      res = JSON.parse(Net::HTTP.post(uri, page.to_json, 'Content-Type' => 'application/json').body)

      controller.instance_variable_set("@_inertia_ssr_head", res['head'].join.html_safe)
      @render_method.call html: res['body'].html_safe, layout: layout, locals: view_data.merge(page: page)
    end

    def layout
      layout = configuration.layout
      layout.nil? ? true : layout
    end

    def shared_data
      controller.__send__(:inertia_shared_data)
    end

    # Cast props to symbol keyed hash before merging so that we have a consistent data structure and
    # avoid duplicate keys after merging.
    #
    # Functionally, this permits using either string or symbol keys in the controller. Since the results
    # is cast to json, we should treat string/symbol keys as identical.
    def merge_props(shared_data, props)
      shared_data.deep_symbolize_keys.send(@deep_merge ? :deep_merge : :merge, props.deep_symbolize_keys)
    end

    def computed_props
      _merged_props = merge_props(shared_data, props)
      validate_partial_props(_merged_props)

      _filtered_props = _merged_props.select do |key, prop|
        if rendering_partial_component?
          key.in? partial_keys
        else
          !prop.is_a?(InertiaRails::Lazy)
        end
      end

      deep_transform_values(
        _filtered_props,
        lambda do |prop|
          prop.respond_to?(:call) ? controller.instance_exec(&prop) : prop
        end
      )
    end

    def page
      {
        component: component,
        props: computed_props,
        url: @request.original_fullpath,
        version: configuration.version,
      }
    end

    def deep_transform_values(hash, proc)
      return proc.call(hash) unless hash.is_a? Hash

      hash.transform_values {|value| deep_transform_values(value, proc)}
    end

    def partial_keys
      (@request.headers['X-Inertia-Partial-Data'] || '').split(',').compact.map(&:to_sym)
    end

    def rendering_partial_component?
      @request.inertia_partial? && @request.headers['X-Inertia-Partial-Component'] == component
    end

    def resolve_component(component)
      return component unless component.is_a? TrueClass

      configuration.component_path_resolver(path: controller.controller_path, action: controller.action_name)
    end

    def validate_partial_props(merged_props)
      return unless rendering_partial_component?

      unrequested_props = merged_props.select do |key, prop|
        !key.in?(partial_keys)
      end

      props_that_will_unecessarily_compute = unrequested_props.select do |key, prop|
        !prop.respond_to?(:call)
      end

      if props_that_will_unecessarily_compute.present?
        props = props_that_will_unecessarily_compute.keys.map { |k| ":#{k}" }.join(', ')
        is_plural = props_that_will_unecessarily_compute.length > 1
        verb = is_plural ? "props are" : "prop is"
        pronoun = is_plural ? "them because they are defined as values" : "it because it is defined as a value"

        warning_message = "The #{props} #{verb} being computed even though your partial reload did not request #{pronoun}. You might want to wrap these in a callable like a lambda ->{} or InertiaRails::Lazy()."

        if configuration.raise_on_unoptimized_partial_reloads
          raise InertiaRails::UnoptimizedPartialReloadError, warning_message
        else
          InertiaRails.warn warning_message
        end
      end
    end
  end
end
