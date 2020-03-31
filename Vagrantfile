# -*- mode: ruby -*-
# vi: set ft=ruby :

# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.
Vagrant.configure("2") do |config|

  config.vm.provider :libvirt do |libvirt|
    libvirt.memory = 4096
    libvirt.disk_bus = 'scsi'
    libvirt.storage :file, :size => '8G', :bus => 'scsi', :cache => 'writeback', :type => 'raw'
    libvirt.cpu_mode = "host-passthrough"
  end

  config.vm.provider :virtualbox do |vb|
    vb.memory = 4096
    disk = "./datadir.vdi"
    unless File.exist?(disk)
        vb.customize ['storagectl', :id, '--name',  'SAS Controller', '--add', 'sas',  '--controller', 'LSILogicSAS', '--portcount', 1]
        vb.customize ['createhd', '--filename', disk, '--size', 8 * 1024]
    end
    vb.customize ['storageattach', :id, '--storagectl', 'SAS Controller', '--port', 0, '--device', 0, '--type', 'hdd', '--medium', "#{disk}"]
  end

  config.vm.define "ubuntu1804", autostart: true do |ubuntu1804|
    ubuntu1804.vm.box        = "generic/ubuntu1804"
    ubuntu1804.vm.hostname   = "replikator-ubuntu1804"
    #ubuntu1804.vm.network    "private_network", ip: "192.168.33.11"
    ubuntu1804.vm.network    "private_network", ip: "10.2.3.4"
  end

    #### vagrant plugin install vagrant-guest_ansible
    config.vm.provision :ansible do |ansible|
      ansible.compatibility_mode = "2.0"
      ansible.playbook = "ansible/playbook.yml"
    end
end

module OS
    def OS.windows?
        (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM) != nil
    end

    def OS.mac?
        (/darwin/ =~ RUBY_PLATFORM) != nil
    end

    def OS.unix?
        !OS.windows?
    end

    def OS.linux?
        OS.unix? and not OS.mac?
    end
end
