#
# Cookbook:: hardware
# Recipe:: default
#
# Copyright:: 2012, OpenStreetMap Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "apt"
include_recipe "git"
include_recipe "prometheus"
include_recipe "sysfs"
include_recipe "tools"

ohai_plugin "hardware" do
  template "ohai.rb.erb"
end

if platform?("debian")
  package "firmware-linux"
end

if node[:cpu] && node[:cpu][:"0"] && node[:cpu][:"0"][:vendor_id]
  case node[:cpu][:"0"][:vendor_id]
  when "GenuineIntel"
    package "intel-microcode"
  when "AuthenticAMD"
    package "amd64-microcode"
  end
end

if node[:dmi] && node[:dmi][:system]
  case node[:dmi][:system][:manufacturer]
  when "empty"
    manufacturer = node[:dmi][:base_board][:manufacturer]
    product = node[:dmi][:base_board][:product_name]
  else
    manufacturer = node[:dmi][:system][:manufacturer]
    product = node[:dmi][:system][:product_name]
  end
else
  manufacturer = "Unknown"
  product = "Unknown"
end

units = []

if node[:roles].include?("bytemark")
  units << "0"
end

case manufacturer
when "HP", "HPE"
  include_recipe "apt::management-component-pack"

  package "hponcfg"

  execute "update-ilo" do
    action :nothing
    command "/usr/sbin/hponcfg -f /etc/ilo-defaults.xml"
    not_if { kitchen? }
  end

  template "/etc/ilo-defaults.xml" do
    source "ilo-defaults.xml.erb"
    owner "root"
    group "root"
    mode "644"
    notifies :run, "execute[update-ilo]"
  end

  package "hp-health" do
    action :install
    notifies :restart, "service[hp-health]"
    only_if { platform?("ubuntu") && node[:lsb][:release].to_f < 22.04 }
  end

  service "hp-health" do
    action [:enable, :start]
    supports :status => true, :restart => true
    only_if { platform?("ubuntu") && node[:lsb][:release].to_f < 22.04 }
  end

  if product.end_with?("Gen8", "Gen9")
    package "hp-ams" do
      action :install
      notifies :restart, "service[hp-ams]"
    end

    service "hp-ams" do
      action [:enable, :start]
      supports :status => true, :restart => true
    end
  elsif product.end_with?("Gen10")
    package "amsd" do
      action :install
      notifies :restart, "service[amsd]"
    end

    service "amsd" do
      action [:enable, :start]
      supports :status => true, :restart => true
    end
  end

  units << if product.end_with?("Gen10")
             "0"
           else
             "1"
           end
when "TYAN"
  units << "0"
when "TYAN Computer Corporation"
  units << "0"
when "Supermicro"
  units << "1"
when "IBM"
  units << "0"
when "VMware, Inc."
  package "open-vm-tools"

  # Remove timeSync plugin completely
  # https://github.com/vmware/open-vm-tools/issues/302
  file "/usr/lib/open-vm-tools/plugins/vmsvc/libtimeSync.so" do
    action :delete
    notifies :restart, "service[open-vm-tools]"
  end

  # Attempt to tell Host we are not interested in timeSync
  execute "vmware-toolbox-cmd-timesync-disable" do
    command "/usr/bin/vmware-toolbox-cmd timesync disable"
    ignore_failure true
  end

  service "open-vm-tools" do
    action [:enable, :start]
    supports :status => true, :restart => true
  end
end

units.sort.uniq.each do |unit|
  service "serial-getty@ttyS#{unit}" do
    action [:enable, :start]
    not_if { kitchen? }
  end
end

# if we need a different / special kernel version to make the hardware
# work (e.g: https://github.com/openstreetmap/operations/issues/45) then
# ensure that we have the package installed. the grub template will
# make sure that this is the default on boot.
if node[:hardware][:grub][:kernel]
  kernel_version = node[:hardware][:grub][:kernel]

  package "linux-image-#{kernel_version}-generic"
  package "linux-image-extra-#{kernel_version}-generic"
  package "linux-headers-#{kernel_version}-generic"
  package "linux-tools-#{kernel_version}-generic"

  boot_device = IO.popen(["df", "/boot"]).readlines.last.split.first
  boot_uuid = IO.popen(["blkid", "-o", "value", "-s", "UUID", boot_device]).readlines.first.chomp
  grub_entry = "gnulinux-advanced-#{boot_uuid}>gnulinux-#{kernel_version}-advanced-#{boot_uuid}"
else
  grub_entry = "0"
end

if File.exist?("/etc/default/grub")
  execute "update-grub" do
    action :nothing
    command "/usr/sbin/update-grub"
    not_if { kitchen? }
  end

  template "/etc/default/grub" do
    source "grub.erb"
    owner "root"
    group "root"
    mode "644"
    variables :units => units, :entry => grub_entry
    notifies :run, "execute[update-grub]"
  end
end

package "initramfs-tools"

execute "update-initramfs" do
  action :nothing
  command "update-initramfs -u -k all"
  user "root"
  group "root"
end

template "/etc/initramfs-tools/conf.d/mdadm" do
  source "initramfs-mdadm.erb"
  owner "root"
  group "root"
  mode "644"
  notifies :run, "execute[update-initramfs]"
end

# haveged is only required on older kernels
# /dev/random is not blocking anymore in 5.15+
if Chef::Util.compare_versions(node[:kernel][:release], [5, 15]).negative?
  package "haveged"
  service "haveged" do
    action [:enable, :start]
  end
else
  service "haveged" do
    action [:stop, :disable]
  end
  package "haveged" do
    action :remove
  end
end

watchdog_module = %w[hpwdt sp5100_tco].find do |module_name|
  node[:hardware][:pci]&.any? { |_, pci| pci[:modules]&.any?(module_name) }
end

if node[:kernel][:modules].include?("ipmi_si")
  package "ipmitool"
  package "freeipmi-tools"

  template "/etc/prometheus/ipmi_local.yml" do
    source "ipmi_local.yml.erb"
    owner "root"
    group "root"
    mode "644"
  end

  prometheus_exporter "ipmi" do
    port 9290
    user "root"
    private_devices false
    protect_clock false
    system_call_filter ["@system-service", "@raw-io"]
    options "--config.file=/etc/prometheus/ipmi_local.yml"
    subscribes :restart, "template[/etc/prometheus/ipmi_local.yml]"
  end

  watchdog_module ||= "ipmi_watchdog"
end

package "irqbalance"

service "irqbalance" do
  action [:start, :enable]
  supports :status => false, :restart => true, :reload => false
end

package "lldpd"

service "lldpd" do
  action [:start, :enable]
  supports :status => true, :restart => true, :reload => true
end

ohai_plugin "lldp" do
  template "lldp.rb.erb"
end

package %w[
  rasdaemon
  ruby-sqlite3
]

service "rasdaemon" do
  action [:enable, :start]
end

prometheus_exporter "rasdaemon" do
  port 9797
  user "root"
end

tools_packages = []
status_packages = {}

if node[:virtualization][:role] != "guest" ||
   (node[:virtualization][:system] != "lxc" &&
    node[:virtualization][:system] != "lxd" &&
    node[:virtualization][:system] != "openvz")

  node[:kernel][:modules].each_key do |modname|
    case modname
    when "cciss"
      tools_packages << "ssacli"
      status_packages["cciss-vol-status"] ||= []
    when "hpsa"
      tools_packages << "ssacli"
      status_packages["cciss-vol-status"] ||= []
    when "mptsas"
      tools_packages << "lsiutil"
      status_packages["mpt-status"] ||= []
    when "mpt2sas", "mpt3sas"
      tools_packages << "sas2ircu"
      status_packages["sas2ircu-status"] ||= []
    when "megaraid_sas"
      tools_packages << "megacli"
      status_packages["megaclisas-status"] ||= []
    when "aacraid"
      tools_packages << "arcconf"
      status_packages["aacraid-status"] ||= []
    when "arcmsr"
      tools_packages << "areca"
    end
  end

  node[:block_device].each do |name, attributes|
    next unless attributes[:vendor] == "HP" && attributes[:model] == "LOGICAL VOLUME"

    if name =~ /^cciss!(c[0-9]+)d[0-9]+$/
      status_packages["cciss-vol-status"] |= ["cciss/#{Regexp.last_match[1]}d0"]
    else
      Dir.glob("/sys/block/#{name}/device/scsi_generic/*").each do |sg|
        status_packages["cciss-vol-status"] |= [File.basename(sg)]
      end
    end
  end
end

include_recipe "apt::hwraid" unless status_packages.empty?

%w[ssacli lsiutil sas2ircu megactl megacli arcconf].each do |tools_package|
  if tools_packages.include?(tools_package)
    package tools_package
  else
    package tools_package do
      action :purge
    end
  end
end

if tools_packages.include?("areca")
  include_recipe "git"

  git "/opt/areca" do
    action :sync
    repository "https://git.openstreetmap.org/private/areca.git"
    depth 1
    user "root"
    group "root"
    not_if { kitchen? }
  end
else
  directory "/opt/areca" do
    action :delete
    recursive true
  end
end

%w[cciss-vol-status mpt-status sas2ircu-status megaclisas-status aacraid-status].each do |status_package|
  if status_packages.include?(status_package)
    package status_package

    service "#{status_package}d" do
      action [:stop, :disable]
    end

    file "/etc/default/#{status_package}d" do
      action :delete
    end
  else
    package status_package do
      action :purge
    end
  end
end

systemd_service "cciss-vol-statusd" do
  action :delete
end

template "/usr/local/bin/cciss-vol-statusd" do
  action :delete
end

disks = if node[:hardware][:disk]
          node[:hardware][:disk][:disks]
        else
          []
        end

intel_ssds = disks.select { |d| d[:vendor] == "INTEL" && d[:model] =~ /^SSD/ }

nvmes = if node[:hardware][:pci]
          node[:hardware][:pci].values.select { |pci| pci[:driver] == "nvme" }
        else
          []
        end

unless nvmes.empty?
  package "nvme-cli"
end

intel_nvmes = nvmes.select { |pci| pci[:vendor_name] == "Intel Corporation" }

if !intel_ssds.empty? || !intel_nvmes.empty?
  package "unzip"

  sst_tool_version = "2-3"
  sst_package_version = "2.3.320-0"

  remote_file "#{Chef::Config[:file_cache_path]}/sst-cli-linux-deb--#{sst_tool_version}.zip" do
    source "https://sdmsdfwdriver.blob.core.windows.net/files/kba-gcc/drivers-downloads/ka-00085/sst--#{sst_tool_version}/sst-cli-linux-deb--#{sst_tool_version}.zip"
  end

  execute "#{Chef::Config[:file_cache_path]}/sst-cli-linux-deb--#{sst_tool_version}.zip" do
    command "unzip sst-cli-linux-deb--#{sst_tool_version}.zip sst_#{sst_package_version}_amd64.deb"
    cwd Chef::Config[:file_cache_path]
    user "root"
    group "root"
    not_if { ::File.exist?("#{Chef::Config[:file_cache_path]}/sst_#{sst_package_version}_amd64.deb") }
  end

  dpkg_package "sst" do
    version sst_package_version
    source "#{Chef::Config[:file_cache_path]}/sst_#{sst_package_version}_amd64.deb"
  end

  dpkg_package "intelmas" do
    action :purge
  end
end

disks = disks.map do |disk|
  next if disk[:state] == "spun_down" || %w[unconfigured failed].any?(disk[:status])

  if disk[:smart_device]
    controller = node[:hardware][:disk][:controllers][disk[:controller]]

    if controller && controller[:device]
      device = controller[:device].sub("/dev/", "")
      smart = disk[:smart_device]
    elsif disk[:device]
      device = disk[:device].sub("/dev/", "")
      smart = disk[:smart_device]
    end
  elsif disk[:device] =~ %r{^/dev/(nvme\d+)n\d+$}
    device = Regexp.last_match(1)
  elsif disk[:device]
    device = disk[:device].sub("/dev/", "")
  end

  next if device.nil?

  Hash[
    :device => device,
    :smart => smart
  ]
end

disks = disks.compact.uniq

if disks.any?
  package "smartmontools"

  template "/etc/cron.daily/update-smart-drivedb" do
    source "update-smart-drivedb.erb"
    owner "root"
    group "root"
    mode "755"
  end

  template "/usr/local/bin/smartd-mailer" do
    source "smartd-mailer.erb"
    owner "root"
    group "root"
    mode "755"
  end

  template "/etc/smartd.conf" do
    source "smartd.conf.erb"
    owner "root"
    group "root"
    mode "644"
    variables :disks => disks
  end

  template "/etc/default/smartmontools" do
    source "smartmontools.erb"
    owner "root"
    group "root"
    mode "644"
  end

  service "smartmontools" do
    action [:enable, :start]
    subscribes :reload, "template[/etc/smartd.conf]"
    subscribes :restart, "template[/etc/default/smartmontools]"
  end

  template "/etc/prometheus/collectors/smart.devices" do
    source "smart.devices.erb"
    owner "root"
    group "root"
    mode "644"
    variables :disks => disks
  end

  prometheus_collector "smart" do
    interval "15m"
    user "root"
    capability_bounding_set %w[CAP_DAC_OVERRIDE CAP_SYS_ADMIN CAP_SYS_RAWIO]
    private_devices false
    private_users false
    protect_clock false
  end
else
  service "smartd" do
    action [:stop, :disable]
  end
end

if File.exist?("/etc/mdadm/mdadm.conf")
  mdadm_conf = edit_file "/etc/mdadm/mdadm.conf" do |line|
    line.gsub!(/^MAILADDR .*$/, "MAILADDR admins@openstreetmap.org")

    line
  end

  file "/etc/mdadm/mdadm.conf" do
    owner "root"
    group "root"
    mode "644"
    content mdadm_conf
  end

  service "mdmonitor" do
    action :nothing
    subscribes :restart, "file[/etc/mdadm/mdadm.conf]"
  end
end

file "/etc/modules" do
  action :delete
end

node[:hardware][:modules].each do |module_name|
  kernel_module module_name do
    action :install
    not_if { kitchen? }
  end
end

node[:hardware][:blacklisted_modules].each do |module_name|
  kernel_module module_name do
    action :blacklist
  end
end

if watchdog_module
  kernel_module watchdog_module do
    action :install
  end

  execute "systemctl-reload" do
    action :nothing
    command "systemctl daemon-reload"
    user "root"
    group "root"
  end

  directory "/etc/systemd/system.conf.d" do
    owner "root"
    group "root"
    mode "755"
  end

  template "/etc/systemd/system.conf.d/watchdog.conf" do
    source "watchdog.conf.erb"
    owner "root"
    group "root"
    mode "644"
    notifies :run, "execute[systemctl-reload]"
  end
end

unless Dir.glob("/sys/class/hwmon/hwmon*").empty?
  package "lm-sensors"

  Dir.glob("/sys/devices/platform/coretemp.*").each do |coretemp|
    cpu = File.basename(coretemp).sub("coretemp.", "").to_i
    chip = format("coretemp-isa-%04d", cpu)

    temps = if File.exist?("#{coretemp}/name")
              Dir.glob("#{coretemp}/temp*_input").map do |temp|
                File.basename(temp).sub("temp", "").sub("_input", "").to_i
              end.sort
            else
              Dir.glob("#{coretemp}/hwmon/hwmon*/temp*_input").map do |temp|
                File.basename(temp).sub("temp", "").sub("_input", "").to_i
              end.sort
            end

    if temps.first == 1
      node.default[:hardware][:sensors][chip][:temps][:temp1][:label] = "CPU #{cpu}"
      temps.shift
    end

    temps.each_with_index do |temp, index|
      node.default[:hardware][:sensors][chip][:temps]["temp#{temp}"][:label] = "CPU #{cpu} Core #{index}"
    end
  end

  execute "/etc/sensors.d/chef.conf" do
    action :nothing
    command "/usr/bin/sensors -s"
    user "root"
    group "root"
  end

  template "/etc/sensors.d/chef.conf" do
    source "sensors.conf.erb"
    owner "root"
    group "root"
    mode "644"
    notifies :run, "execute[/etc/sensors.d/chef.conf]"
  end
end

if node[:hardware][:shm_size]
  execute "remount-dev-shm" do
    action :nothing
    command "/bin/mount -o remount /dev/shm"
    user "root"
    group "root"
  end

  mount "/dev/shm" do
    action :enable
    device "tmpfs"
    fstype "tmpfs"
    options "rw,nosuid,nodev,size=#{node[:hardware][:shm_size]}"
    notifies :run, "execute[remount-dev-shm]"
  end
end

prometheus_collector "ohai" do
  interval "15m"
  user "root"
  proc_subset "all"
  capability_bounding_set %w[CAP_DAC_OVERRIDE CAP_SYS_ADMIN CAP_SYS_RAWIO]
  private_devices false
  private_users false
  protect_clock false
  protect_kernel_modules false
end
