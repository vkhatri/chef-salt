#
# Cookbook Name:: chef-salt
# Recipe:: minion
#
# Copyright (C) 2016, Grant Ridder
# Copyright (C) 2014, Daryl Robbins
#
#
#

# TODO: call sync grains command in Salt periodically to ensure the autmatic
# grains stay in sync.

require 'mixlib/shellout'
include_recipe 'salt::_setup'

package node['salt']['minion']['package'] do
  version node['salt']['version'] if node['salt']['version']
  options node['salt']['minion']['install_opts'] unless node['salt']['minion']['install_opts'].nil?
  action :install
end

service 'salt-minion' do
  action :enable
end

if node['salt']['minion']['master']
  master = [node['salt']['minion']['master']]
else
  master_search = "role:#{node['salt']['role']['master']}"
  if node['salt']['minion']['master_environment'] && node['salt']['minion']['master_environment'] != '_default'
    master_search += " AND chef_environment:#{node['salt']['minion']['master_environment']}"
  end

  if Chef::Config[:solo]
    log 'Master search not supported on Chef solo' do
      level :warn
    end
  else
    master_nodes = search(:node, master_search)

    # TODO: Find best IP address
    master = master_nodes.collect { |n| n['ipaddress'] }
  end
end

raise 'No salt-master found' unless master && master.length >= 1

config = node['salt']['minion']['config'].to_hash
config['grains']['environment'] = node.chef_environment
config['grains']['role'] = node['roles'].to_a
config['master'] = master

template '/etc/salt/minion' do
  source node['salt']['minion']['config_template'] || 'minion.erb'
  cookbook node['salt']['minion']['config_cookbook'] || 'salt'
  owner 'root'
  group 'root'
  mode '0644'
  variables(
    config: config
  )
  helpers SaltCookbookHelper
  notifies :restart, 'service[salt-minion]', :delayed
  notifies :run, 'execute[wait for salt-minion]', :delayed
end

# We need to wait for salt-minion to generate the key, so we can capture it
execute 'wait for salt-minion' do
  command 'sleep 5'
  action :nothing
  notifies :reload, 'ohai[salt]', :immediate
end

# Stub for chefspec since we test each recipe in isolation
ohai 'salt' do
  action :nothing
end if defined?(ChefSpec)

api_password = node['salt']['key_accept_method'] == 'api_key_accept' ? Chef::EncryptedDataBagItem.load(node['salt']['minion']['api']['databag']['name'], node['salt']['minion']['api']['databag']['item'])[node['salt']['minion']['api']['databag']['key']] : nil

# salt api key accept
options = { 'host' => node['salt']['minion']['api']['host'],
            'port' => node['salt']['minion']['api']['port'],
            'username' => node['salt']['minion']['api']['username'],
            'password' => api_password,
            'minion' => node['hostname'],
            'eauth' => node['salt']['minion']['api']['eauth'],
            'use_ssl' => node['salt']['minion']['api']['use_ssl'],
            'verify' => node['salt']['minion']['api']['verify'] }

ruby_block 'delayed notify' do
  block do
  end
  notifies :run, 'ruby_block[accept_salt_key]'
end

ruby_block 'accept_salt_key' do
  block do
    salt_accept_key(options)
  end
  only_if { node['salt']['key_accept_method'] == 'api_key_accept' && Mixlib::ShellOut.new('salt-call test.ping').run_command.exitstatus != 0 }
  action :nothing
end
