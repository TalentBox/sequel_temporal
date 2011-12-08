module Sequel
  module Plugins
    module Temporal
      def self.at(time)
        raise ArgumentError, "requires a block" unless block_given?
        key = :sequel_plugins_temporal_now
        previous, Thread.current[key] = Thread.current[key], time.to_time
        yield
        Thread.current[key] = previous
      end

      def self.now
        Thread.current[:sequel_plugins_temporal_now] || Time.now
      end

      def self.configure(master, opts = {})
        version = opts[:version_class]
        raise Error, "please specify version class to use for temporal plugin" unless version
        required = [:master_id, :created_at, :expired_at]
        missing = required - version.columns
        raise Error, "temporal plugin requires the following missing column#{"s" if missing.size>1} on version class: #{missing.join(", ")}" unless missing.empty?
        master.instance_eval do
          @version_class = version
          base_alias = name ? underscore(demodulize(name)) : table_name
          @versions_alias = "#{base_alias}_versions".to_sym
          @current_version_alias = "#{base_alias}_current_version".to_sym
        end
        master.one_to_many :versions, class: version, key: :master_id, graph_alias_base: master.versions_alias
        master.one_to_one :current_version, class: version, key: :master_id, graph_alias_base: master.current_version_alias, :graph_block=>(proc do |j, lj, js|
          n = ::Sequel::Plugins::Temporal.now
          e = :expired_at.qualify(j)
          (:created_at.qualify(j) <= n) & ({e=>nil} | (e > n))
        end) do |ds|
          n = ::Sequel::Plugins::Temporal.now
          ds.where{(created_at <= n) & ({expired_at=>nil} | (expired_at > n))}
        end
        master.def_dataset_method :with_current_version do
          eager_graph(:current_version).where({:id.qualify(model.current_version_alias) => nil}.sql_negate)
        end
        version.many_to_one :master, class: master, key: :master_id
        version.class_eval do
          def current?
            n = ::Sequel::Plugins::Temporal.now
            !new? &&
            created_at.to_time<=n &&
            (expired_at.nil? || expired_at.to_time>n)
          end
        end
        unless opts[:delegate]==false
          (version.columns-required-[:id]).each do |column|
            master.class_eval <<-EOS
              def #{column}
                pending_or_current_version.#{column} if pending_or_current_version
              end
            EOS
          end
        end
      end
      module ClassMethods
        attr_reader :version_class, :versions_alias, :current_version_alias
      end
      module DatasetMethods
      end
      module InstanceMethods
        attr_reader :pending_version

        def before_validation
          prepare_pending_version
          super
        end

        def validate
          super
          pending_version.errors.each do |key, key_errors|
            key_errors.each{|error| errors.add key, error}
          end if pending_version && !pending_version.valid?
        end

        def pending_or_current_version
          pending_version || current_version
        end

        def attributes
          if pending_version
            pending_version.values
          elsif current_version
            current_version.values
          else
            {}
          end
        end

        def attributes=(attributes)
          if !new? && attributes.delete(:partial_update) && current_version
            current_attributes = current_version.keys.inject({}) do |hash, key|
              hash[key] = current_version.send key
              hash
            end
            attributes = current_attributes.merge attributes
          end
          attributes.delete :id
          @pending_version ||= model.version_class.new
          pending_version.set attributes
          pending_version.master_id = id unless new?
        end

        def update_attributes(attributes={})
          self.attributes = attributes
          save raise_on_failure: false
        end

        def after_create
          super
          if pending_version
            return false unless save_pending_version
          end
        end

        def before_update
          if pending_version
            expire_previous_version
            return false unless save_pending_version
          end
          super
        end

        def destroy
          versions_dataset.where(expired_at: nil).update expired_at: Time.now
        end

      private

        def prepare_pending_version
          return unless pending_version
          pending_version.created_at = Time.now
        end

        def expire_previous_version
          lock!
          versions_dataset.where(expired_at: nil).update expired_at: pending_version.created_at
        end

        def save_pending_version
          success = add_version pending_version
          @pending_version = nil if success
          success
        end
      end
    end
  end
end
