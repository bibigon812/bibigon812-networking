Puppet::Type.type(:quagga_bgp_as_path).provide :quagga do
  @doc = %q{
    Manages as-path access-list using quagga.
  }

  commands :vtysh => 'vtysh'

  def self.instances
    providers = []
    hash = {}
    previous_name = ''

    config = vtysh('-c', 'show running-config')
    config.split(/\n/).collect do |line|
      if line =~ /\Aip\sas-path\saccess-list\s([\w]+)\s(permit|deny)\s(.+)\Z/
        name = $1
        action = $2
        regexp = $3

        unless name == previous_name
          unless hash.empty?
            debug 'Instantiated the bgp as-path %{name}.' % {
              :name => hash[:name],
            }

            providers << new(hash)
          end

          hash = {
              :ensure => :present,
              :name => name,
              :provider => self.name,
              :rules => [],
          }
        end

        regexp.split(/\s/).each do |r|
          hash[:rules] <<  "#{action} #{r}"
        end

        previous_name = name
      end
    end

    unless hash.empty?
      debug 'Instantiated the bgp as-path %{name}.' % {
        :name => hash[:name],
      }

      providers << new(hash)
    end

    providers
  end

  def self.prefetch(resources)
    providers = instances
    resources.keys.each do |name|
      if provider = providers.find { |provider| provider.name == name }
        resources[name].provider = provider
      end
    end
  end

  def create
    debug 'Creating the bgp as-path %{name}.' % {
      :name => @resource[:name]
    }

    cmds = []
    cmds << 'configure terminal'

    @resource[:rules].each do |rule|
      cmds << 'ip as-path access-list %{name} %{rule}' % {
        :name => @resource[:name],
        :rule => rule,
      }
    end

    cmds << 'end'
    cmds << 'write memory'
    vtysh(cmds.reduce([]){ |cmds, cmd| cmds << '-c' << cmd })

    @property_hash[:ensure] = :present
  end

  def destroy
    debug 'Destroying the bgp as-path %{name}.' % {
      :name => @property_hash[:name],
    }

    cmds = []
    cmds << 'configure terminal'

    cmds << 'no ip as-path access-list %{name}' % {
      :name => @property_hash[:name],
    }

    cmds << 'end'
    cmds << 'write memory'
    vtysh(cmds.reduce([]){ |cmds, cmd| cmds << '-c' << cmd })

    @property_hash.clear
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def rules
    @property_hash[:rules] || :absent
  end

  def rules=(value)
    destroy
    create unless value.empty?

    @property_hash[:rules] = value
  end
end
