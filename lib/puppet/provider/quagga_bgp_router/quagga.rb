Puppet::Type.type(:quagga_bgp_router).provide :quagga do
  @doc = %q{ Manages as-path access-list using quagga }

  commands :vtysh => 'vtysh'

  @resource_map = {
      :import_check => {
          :default  => :false,
          :regexp   => /\A\sbgp\snetwork\simport-check\Z/,
          :template => 'bgp network import-check',
          :type     => :boolean,
      },
      :default_ipv4_unicast => {
          :default  => :true,
          :regexp   => /\A\sno\sbgp\sdefault\sipv4-unicast\Z/,
          :template => 'bgp default ipv4-unicast',
          :type     => :boolean,
      },
      :default_local_preference => {
          :default  => 100,
          :regexp   => /\A\sbgp\sdefault\slocal-preference\s(\d+)\Z/,
          :template => 'bgp default local-preference<% unless value.nil? %> <%= value %><% end %>',
          :type     => :fixnum,
      },
      :redistribute => {
          :regexp   => /\A\sredistribute\s(.+)\Z/,
          :template => 'redistribute <%= value %>',
          :type     => :array,
          :default  => [],
      },
      :router_id => {
          :regexp   => /\A\sbgp\srouter-id\s(\d+\.\d+\.\d+\.\d+)\Z/,
          :template => 'bgp router-id<% unless value.nil? %> <%= value %><% end %>',
          :type     => :string,
      },
      :keepalive => {
          :default  => 3,
          :type     => :fixnum,
      },
      :holdtime => {
          :default  => 9,
          :type     => :fixnum,
      },
  }

  @timers_regexp = /\A\stimers\sbgp\s(\d+)\s(\d+)\Z/
  @timers_template = 'timers bgp <%= keepalive %> <%= holdtime %>'

  def initialize(value)
    super(value)
    @property_flush = {}
  end

  def self.default_router_id
    default_router_id = :absent
    begin
      vtysh('-c', 'show running-config').split(/\n/).collect.each do |line|
        if line =~ /\A\sbgp\srouter-id\s(\d+\.\d+\.\d+\.\d+)\Z/
          default_router_id = Integer($1)
          break
        end
      end
    rescue
    end

    default_router_id
  end

  def self.instances
    debug '[instances]'

    providers = []
    found_bgp = false
    hash = {}

    config = vtysh('-c', 'show running-config')
    config.split(/\n/).collect do |line|
      next if line =~ /\A!/
      if line =~ /\Arouter\sbgp\s(\d+)\Z/
        as_number = $1
        found_bgp = true

        hash = {
            :as_number => as_number,
            :ensure    => :present,
            :name      => 'bgp',
            :provider  => self.name,
        }

        # Added default values
        @resource_map.each do |property, options|
          if [:array, :hash].include?(options[:type])
            hash[property] = options[:default].clone
          else
            hash[property] = options[:default]
          end
        end

      # Exit
      elsif line =~ /\A\w/ and found_bgp
        break

      elsif found_bgp
        if line =~ @timers_regexp
          hash[:keepalive] = $1.to_i
          hash[:holdtime] = $2.to_i
          next
        end
        @resource_map.each do |property, options|
          next unless options[:regexp]
          if line =~ options[:regexp]
            value = $1

            if value.nil?
              hash[property] = options[:default] == :false ? :true : :false
            else
              case options[:type]
                when :array
                  hash[property] << value

                when :fixnum
                  hash[property] = value.to_i

                when :boolean
                  hash[property] = :true

                when :symbol
                  hash[property] = value.gsub(/-/, '_').to_sym

                when :string
                  hash[property] = value
              end
            end

            break
          end
        end
      end
    end

    unless hash.empty?
      debug ":bgp => #{hash}"
      providers << new(hash)
    end

    providers
  end

  def self.prefetch(resources)
    debug '[prefetch]'
    providers = instances
    resources.keys.each do |name|
      if provider = providers.find { |provider| provider.name == name }
        resources[name].provider = provider
      end
    end
  end

  def create
    as_number = @resource[:as_number]

    debug 'Creating the bgp router %{as_number}' % { :as_number => as_number }

    resource_map = self.class.instance_variable_get('@resource_map')

    custom_timers = false

    cmds = []
    cmds << 'configure terminal'
    cmds << 'router bgp %{as_number}' % { :as_number => as_number }

    resource_map.each do |property, options|
      if @resource[property] and @resource[property] != options[:default]
        if [:keepalive, :holdtime].include? property
          custom_timers = true
        elsif @resource[property] == :true
          cmds << ERB.new(options[:template]).result(binding)

        elsif @resource[property] == :false
          cmds << 'no %{command}' % { :command => ERB.new(options[:template]).result(binding) }

        elsif options[:type] == :array
          @resource[property].each do |value|
            cmds << ERB.new(options[:template]).result(binding)
          end

        else
          value = @resource[property]
          cmds << ERB.new(options[:template]).result(binding)
        end
      end
    end

    if custom_timers
      keepalive = @resource[:keepalive] || resource_map[:keepalive][:default]
      holdtime = @resource[:holdtime] || resource_map[:holdtime][:default]
      cmds << ERB.new(self.class.instance_variable_get('@timers_template')).result(binding)
    end

    cmds << 'end'
    cmds << 'write memory'

    vtysh(cmds.reduce([]){ |commands, command| commands << '-c' << command })

    @property_hash[:ensure] = :present
  end

  def destroy
    as_number = @property_hash[:as_number]

    debug 'Destroying the bgp router %{as_number}' % { :as_number => as_number }

    cmds = []
    cmds << 'configure terminal'
    cmds << 'no router bgp %{as_number}' % { :as_number => as_number }
    cmds << 'end'
    cmds << 'write memory'

    vtysh(cmds.reduce([]){ |commands, command| commands << '-c' << command })

    @property_hash.clear
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def flush
    return if @property_flush.empty?

    as_number = @property_hash[:as_number]

    debug 'Flushing the bgp router %{as_number}' % { :as_number => as_number }

    resource_map = self.class.instance_variable_get('@resource_map')

    custom_timers = false

    cmds = []
    cmds << 'configure terminal'
    cmds << 'router bgp %{as_number}' % { :as_number => as_number }

    @property_flush.each do |property, v|
      if [:keepalive, :holdtime].include? property
        custom_timers = true

      elsif v == :absent or v == :false
        cmds << 'no %{command}' % { :command => ERB.new(resource_map[property][:template]).result(binding) }

      elsif [:true, 'true'].include?(v) and [:symbol, :string].include?(resource_map[property][:type])
        cmds << 'no %{command}' % { :command => ERB.new(resource_map[property][:template]).result(binding) }
        cmds << ERB.new(resource_map[property][:template]).result(binding)

      elsif v == :true
        cmds << ERB.new(resource_map[property][:template]).result(binding)

      elsif resource_map[property][:type] == :array
        (@property_hash[property] - v).each do |value|
          cmds << 'no %{command}' % {:command => ERB.new(resource_map[property][:template]).result(binding) }
        end

        (v - @property_hash[property]).each do |value|
          cmds << ERB.new(resource_map[property][:template]).result(binding)
        end

      else
        value = v
        cmds << ERB.new(resource_map[property][:template]).result(binding)
      end
    end

    if custom_timers
      keepalive = @property_flush[:keepalive] || @property_hash[:keepalive] || resource_map[:keepalive][:default]
      holdtime = @property_flush[:holdtime] || @property_hash[:holdtime] || resource_map[:holdtime][:default]
      cmds << ERB.new(self.class.instance_variable_get('@timers_template')).result(binding)
    end

    cmds << 'end'
    cmds << 'write memory'

    vtysh(cmds.reduce([]){ |commands, command| commands << '-c' << command })

    @property_hash = resource.to_hash
    @property_flush.clear
  end

  def as_number
    @property_hash[:as_number]
  end

  def as_number=(value)
    @property_hash[:as_number] = value
  end

  @resource_map.keys.each do |property|
    define_method "#{property}" do
      @property_hash[property] || :absent
    end

    define_method "#{property}=" do |value|
      @property_flush[property] = value
    end
  end
end
