if node[:lsb][:release].to_f < 20.04
  default[:passenger][:ruby_version] = "2.5"
else
  default[:passenger][:ruby_version] = "2.7"
end

default[:passenger][:max_pool_size] = 6
default[:passenger][:pool_idle_time] = 300
default[:passenger][:instance_registry_dir] = "/run/passenger"

default[:apt][:sources] = node[:apt][:sources] | ["passenger"]
