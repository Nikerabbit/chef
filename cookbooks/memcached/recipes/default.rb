#
# Cookbook Name:: memcached
# Recipe:: default
#
# Copyright 2011, OpenStreetMap Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package "memcached"

service "memcached" do
  action [:enable, :start]
  supports :status => true, :restart => true
end

template "/etc/memcached.conf" do
  source "memcached.conf.erb"
  owner "root"
  group "root"
  mode 0o644
  notifies :restart, "service[memcached]"
end

munin_plugin_conf "memcached_multi" do
  template "munin.erb"
end

%w[bytes commands conns evictions items memory].each do |stat|
  munin_plugin "memcached_multi_#{stat}" do
    target "memcached_multi_"
  end
end
