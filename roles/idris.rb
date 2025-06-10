name "idris"
description "Master role applied to idris"

default_attributes(
  :apache => {
    :event => {
      :server_limit => 30,
      :max_request_workers => 1000,
      :threads_per_child => 50,
      :min_spare_threads => 75,
      :max_spare_threads => 525,
      :async_request_worker_factor => 10
    }
  },
  :networking => {
    :interfaces => {
      :internal => {
        :inet => {
          :address => "10.0.64.6"
        },
        :bond => {
          :slaves => %w[eno1 eno2 eno3 eno4 eno49 eno50]
        }
      },
      :henet => {
        :inet => {
          :address => "184.104.226.102"
        },
        :inet6 => {
          :address => "2001:470:1:b3b::6"
        }
      },
      :equinix => {
        :inet => {
          :address => "87.252.214.102"
        },
        :inet6 => {
          :address => "2001:4d78:fe03:1c::6"
        }
      }
    }
  }
)

run_list(
  "role[equinix-dub-public]",
  "role[hp-g9]",
  "role[chef-server]",
  "role[chef-repository]",
  "role[dns]",
  "role[git]",
  "role[letsencrypt]",
  "role[oxidized]",
  "role[supybot]",
  "role[apt]",
  "recipe[serverinfo]"
)
