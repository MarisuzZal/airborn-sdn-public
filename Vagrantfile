# Vagrantfile
# Vagrant VM definition for the BMv2 reference track.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-22.04"
  config.vm.hostname = "airborn-sdn"

  config.vm.synced_folder ".", "/vagrant"

  config.vm.provider "virtualbox" do |vb|
    vb.name   = "airborn-sdn"
    vb.memory = 4096
    vb.cpus   = 2
  end

  config.vm.provision "shell", privileged: false, path: "provision.sh"
end
