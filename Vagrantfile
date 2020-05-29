# -*- mode: ruby -*-
# vi: set ft=ruby :

# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.

# Vagrant base box to use
BOX_BASE = "generic/ubuntu1804"
# amount of RAM for Vagrant box
BOX_RAM_MB = "4096"

Vagrant.configure("2") do |config|

  config.vm.provider :libvirt do |libvirt|
    libvirt.memory = BOX_RAM_MB
    libvirt.disk_bus = 'scsi'
    libvirt.storage :file, :size => '8G', :bus => 'scsi', :cache => 'writeback', :type => 'raw'
    libvirt.cpu_mode = "host-passthrough"
  end

  config.vm.provider :virtualbox do |vb|
    vb.memory = BOX_RAM_MB
    disk = "./datadir.vdi"
    unless File.exist?(disk)
        vb.customize ['storagectl', :id, '--name',  'SAS', '--add', 'sas',  '--controller', 'LSILogicSAS', '--portcount', 1]
        vb.customize ['createhd', '--filename', disk, '--size', 8 * 1024]
    end
    vb.customize ['storageattach', :id, '--storagectl', 'SAS', '--port', 0, '--device', 0, '--type', 'hdd', '--medium', "#{disk}"]
  end

  config.vm.define "replikator", autostart: true do |replikator|
    replikator.vm.box        = BOX_BASE
    replikator.vm.hostname   = "replikator"
    replikator.vm.network    "private_network", ip: "10.2.3.4"
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
