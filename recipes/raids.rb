package "mdadm"
package "lvm2"

execute "Load device mapper kernel module" do
  command "modprobe dm-mod"
  ignore_failure true
end

if node[:ebs][:creds][:encrypted]
  credentials = Chef::EncryptedDataBagItem.load(node[:ebs][:creds][:databag], node[:ebs][:creds][:item])
else
  credentials = data_bag_item node[:ebs][:creds][:databag], node[:ebs][:creds][:item]
end

node[:ebs][:raids].each do |device, options|
  disks = []
  if !options[:disks] && options[:num_disks]
    devices = Dir.glob('/dev/xvd*')
    if devices.empty?
      next_mount = "a"
    else
      next_mount = devices.map{ |x| x[0,9] }.uniq.sort.last[-1,1].succ
    end
    1.upto(options[:num_disks].to_i) do |i|
      disks << mount = "/dev/sd#{next_mount}"
      next_mount = next_mount.succ

      vol = aws_ebs_volume mount do
        aws_access_key credentials[node.ebs.creds.aki]
        aws_secret_access_key credentials[node.ebs.creds.sak]
        size options[:disk_size]
        device mount
        availability_zone node[:ec2][:placement_availability_zone]
        volume_type options[:piops] ? 'io1' : 'standard'
        piops options[:piops]
        action :nothing
      end
      vol.run_action(:create)
      vol.run_action(:attach)
    end
  end
  node.set[:ebs][:raids][device][:disks] = disks.map { |d| d.sub('/sd', '/xvd') } if !disks.empty?
  node.save unless Chef::Config[:solo]
end

node[:ebs][:raids].each do |raid_device, options|
  lvm_device = BlockDevice.lvm_device(raid_device)

  Chef::Log.info("Waiting for individual disks of RAID #{options[:mount_point]}")
  options[:disks].each do |disk_device|
    BlockDevice::wait_for(disk_device)
  end

  ruby_block "Create or resume RAID array #{raid_device}" do
    block do
      if BlockDevice.existing_raid_at?(raid_device)
        if BlockDevice.assembled_raid_at?(raid_device)
          Chef::Log.info "Skipping RAID array at #{raid_device} - already assembled and probably mounted at #{options[:mount_point]}"
        else
          BlockDevice.assemble_raid(raid_device, options)
        end
      else
        BlockDevice.create_raid(raid_device, node[:ebs][:mdadm_chunk_size], options)
      end

      BlockDevice.set_read_ahead(raid_device, node[:ebs][:md_read_ahead])
    end
  end

  devicetomount = raid_device
  if options[:use_lvm] == true
    ruby_block "Create or attach LVM volume out of #{raid_device}" do
      block do
        BlockDevice.create_lvm(raid_device, options)
      end
    end
    devicetomount = lvm_device
  end

  execute "mkfs" do
    command "mkfs -t #{options[:fstype]} #{devicetomount}"

    not_if do
      # check volume filesystem
      system("blkid -s TYPE -o value #{devicetomount}")
    end
  end

  directory options[:mount_point] do
    recursive true
    action :create
    mode "0755"
  end

  mount options[:mount_point] do
    fstype options[:fstype]
    device devicetomount
    options "noatime"
    not_if do
      File.read('/etc/mtab').split("\n").any?{|line| line.match(" #{options[:mount_point]} ")}
    end
  end

  mount options[:mount_point] do
    action :enable
    fstype options[:fstype]
    device devicetomount
    options "noatime"
  end

  execute "/usr/share/mdadm/mkconf force-generate /etc/mdadm/mdadm.conf"

  initrd = "/boot/initrd.img-#{node['kernel']['release']}"
  if File.exists?(initrd)
    initmd5 = Digest::MD5.hexdigest(IO.read(initrd))
    geninitrd = initmd5 != node['ebs']['initrd_md5']
    Chef::Log.debug("oldinitrd md5: #{initmd5}")
  else
    geninitrd = true
  end

  execute "update-initramfs -u" do
    action :run
    only_if { geninitrd }
  end

  ruby_block "calculate new md5" do
    block do
      node.set['ebs']['initrd_md5'] = Digest::MD5.hexdigest(IO.read(initrd)) if geninitrd
      Chef::Log.debug("after initrd md5: #{node['ebs']['initrd_md5']}")
    end
    action :create
  end

  template "/etc/rc.local" do
    source "rc.local.erb"
    mode 0755
    owner 'root'
    group 'root'
  end
end
