#
# Cookbook Name:: tile
# Recipe:: default
#
# Copyright 2013, OpenStreetMap Foundation
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

include_recipe "apache"
include_recipe "git"
include_recipe "nodejs"
include_recipe "postgresql"
include_recipe "python"
include_recipe "tools"

blocks = data_bag_item("tile", "blocks")
web_passwords = data_bag_item("web", "passwords")

apache_module "alias"
apache_module "cgi"
apache_module "expires"
apache_module "headers"
apache_module "remoteip"
apache_module "rewrite"

apache_module "tile" do
  conf "tile.conf.erb"
end

tilecaches = search(:node, "roles:tilecache").sort_by { |n| n[:hostname] }

apache_site "default" do
  action [:disable]
end

apache_site "tile.openstreetmap.org" do
  template "apache.erb"
  variables :caches => tilecaches
end

template "/etc/logrotate.d/apache2" do
  source "logrotate.apache.erb"
  owner "root"
  group "root"
  mode 0o644
end

directory "/srv/tile.openstreetmap.org" do
  owner "tile"
  group "tile"
  mode 0o755
end

package "renderd"

systemd_service "renderd" do
  description "Mapnik rendering daemon"
  after "postgresql.service"
  wants "postgresql.service"
  user "www-data"
  exec_start "/usr/bin/renderd -f"
  runtime_directory "renderd"
  standard_error "null"
  private_tmp true
  private_devices true
  private_network true
  protect_system "full"
  protect_home true
  no_new_privileges true
  restart "on-failure"
end

service "renderd" do
  action [:enable, :start]
  subscribes :restart, "systemd_service[renderd]"
end

directory "/srv/tile.openstreetmap.org/tiles" do
  owner "tile"
  group "tile"
  mode 0o755
end

template "/etc/renderd.conf" do
  source "renderd.conf.erb"
  owner "root"
  group "root"
  mode 0o644
  notifies :reload, "service[apache2]"
  notifies :restart, "service[renderd]"
end

remote_directory "/srv/tile.openstreetmap.org/html" do
  source "html"
  owner "tile"
  group "tile"
  mode 0o755
  files_owner "tile"
  files_group "tile"
  files_mode 0o644
end

template "/srv/tile.openstreetmap.org/html/index.html" do
  source "index.html.erb"
  owner "tile"
  group "tile"
  mode 0o644
end

package "python-cairo"
package "python-mapnik"
package "python-setuptools"

python_package "pyotp"

package "fonts-noto-cjk"
package "fonts-noto-hinted"
package "fonts-noto-unhinted"
package "fonts-hanazono"
package "ttf-unifont"

directory "/srv/tile.openstreetmap.org/cgi-bin" do
  owner "tile"
  group "tile"
  mode 0o755
end

template "/srv/tile.openstreetmap.org/cgi-bin/export" do
  source "export.erb"
  owner "tile"
  group "tile"
  mode 0o755
  variables :blocks => blocks, :totp_key => web_passwords["totp_key"]
end

template "/srv/tile.openstreetmap.org/cgi-bin/debug" do
  source "debug.erb"
  owner "tile"
  group "tile"
  mode 0o755
end

template "/etc/cron.hourly/export" do
  source "export.cron.erb"
  owner "root"
  group "root"
  mode 0o755
end

directory "/srv/tile.openstreetmap.org/data" do
  owner "tile"
  group "tile"
  mode 0o755
end

package "mapnik-utils"

node[:tile][:data].each_value do |data|
  url = data[:url]
  file = "/srv/tile.openstreetmap.org/data/#{File.basename(url)}"

  if data[:directory]
    directory = "/srv/tile.openstreetmap.org/data/#{data[:directory]}"

    directory directory do
      owner "tile"
      group "tile"
      mode 0o755
    end
  else
    directory = "/srv/tile.openstreetmap.org/data"
  end

  if file =~ /\.tgz$/
    package "tar"

    execute file do
      action :nothing
      command "tar -zxf #{file} -C #{directory}"
      user "tile"
      group "tile"
    end
  elsif file =~ /\.tar\.bz2$/
    package "tar"

    execute file do
      action :nothing
      command "tar -jxf #{file} -C #{directory}"
      user "tile"
      group "tile"
    end
  elsif file =~ /\.zip$/
    package "unzip"

    execute file do
      action :nothing
      command "unzip -qq -o #{file} -d #{directory}"
      user "tile"
      group "tile"
    end
  end

  execute "#{file}_shapeindex" do
    action :nothing
    command "find #{directory} -type f -iname '*.shp' -print0 | xargs -0 --no-run-if-empty shapeindex --shape_files"
    user "tile"
    group "tile"
    subscribes :run, "execute[#{file}]", :immediately
  end

  remote_file file do
    if data[:refresh]
      action :create
      use_conditional_get true
      ignore_failure true
    else
      action :create_if_missing
    end

    source url
    owner "tile"
    group "tile"
    mode 0o644
    backup false
    notifies :run, "execute[#{file}]", :immediately
    notifies :restart, "service[renderd]"
  end
end

nodejs_package "carto"
nodejs_package "millstone"

systemd_service "update-lowzoom@" do
  description "Low zoom tile update service for %i layer"
  user "tile"
  exec_start "/bin/bash /usr/local/bin/update-lowzoom-%i"
  private_tmp true
  private_devices true
  private_network true
  protect_system "full"
  protect_home true
  no_new_privileges true
  restart "on-failure"
end

directory "/srv/tile.openstreetmap.org/styles" do
  owner "tile"
  group "tile"
  mode 0o755
end

node[:tile][:styles].each do |name, details|
  style_directory = "/srv/tile.openstreetmap.org/styles/#{name}"
  tile_directory = "/srv/tile.openstreetmap.org/tiles/#{name}"

  template "/usr/local/bin/update-lowzoom-#{name}" do
    source "update-lowzoom.erb"
    owner "root"
    group "root"
    mode 0o755
    variables :style => name
  end

  service "update-lowzoom@#{name}" do
    action :disable
    supports :restart => true
  end

  directory tile_directory do
    owner "tile"
    group "tile"
    mode 0o755
  end

  details[:tile_directories].each do |directory|
    directory directory[:name] do
      owner "www-data"
      group "www-data"
      mode 0o755
    end

    directory[:min_zoom].upto(directory[:max_zoom]) do |zoom|
      directory "#{directory[:name]}/#{zoom}" do
        owner "www-data"
        group "www-data"
        mode 0o755
      end

      link "#{tile_directory}/#{zoom}" do
        to "#{directory[:name]}/#{zoom}"
        owner "tile"
        group "tile"
      end
    end
  end

  file "#{tile_directory}/planet-import-complete" do
    action :create_if_missing
    owner "tile"
    group "tile"
    mode 0o444
  end

  git style_directory do
    action :sync
    repository details[:repository]
    revision details[:revision]
    user "tile"
    group "tile"
  end

  link "#{style_directory}/data" do
    to "/srv/tile.openstreetmap.org/data"
    owner "tile"
    group "tile"
  end

  execute "#{style_directory}/project.mml" do
    action :nothing
    command "carto -a 3.0.0 project.mml > project.xml"
    cwd style_directory
    user "tile"
    group "tile"
    subscribes :run, "git[#{style_directory}]"
    notifies :restart, "service[renderd]", :immediately
    notifies :restart, "service[update-lowzoom@#{name}]"
  end
end

postgresql_version = node[:tile][:database][:cluster].split("/").first

package "postgis"
package "postgresql-#{postgresql_version}-postgis-2.3"

postgresql_user "jburgess" do
  cluster node[:tile][:database][:cluster]
  superuser true
end

postgresql_user "tomh" do
  cluster node[:tile][:database][:cluster]
  superuser true
end

postgresql_user "tile" do
  cluster node[:tile][:database][:cluster]
end

postgresql_user "www-data" do
  cluster node[:tile][:database][:cluster]
end

postgresql_database "gis" do
  cluster node[:tile][:database][:cluster]
  owner "tile"
end

postgresql_extension "postgis" do
  cluster node[:tile][:database][:cluster]
  database "gis"
end

postgresql_extension "hstore" do
  cluster node[:tile][:database][:cluster]
  database "gis"
end

%w[geography_columns planet_osm_nodes planet_osm_rels planet_osm_ways raster_columns raster_overviews spatial_ref_sys].each do |table|
  postgresql_table table do
    cluster node[:tile][:database][:cluster]
    database "gis"
    owner "tile"
    permissions "tile" => :all
  end
end

%w[geometry_columns planet_osm_line planet_osm_point planet_osm_polygon planet_osm_roads].each do |table|
  postgresql_table table do
    cluster node[:tile][:database][:cluster]
    database "gis"
    owner "tile"
    permissions "tile" => :all, "www-data" => :select
  end
end

postgresql_munin "gis" do
  cluster node[:tile][:database][:cluster]
  database "gis"
end

file node[:tile][:node_file] do
  owner "tile"
  group "www-data"
  mode 0o640
end

directory "/var/log/tile" do
  owner "tile"
  group "tile"
  mode 0o755
end

package "osm2pgsql"
package "osmosis"

package "ruby"
package "ruby-dev"

package "libproj-dev"
package "libxml2-dev"

gem_package "proj4rb"
gem_package "libxml-ruby"

remote_directory "/usr/local/lib/site_ruby" do
  source "ruby"
  owner "root"
  group "root"
  mode 0o755
  files_owner "root"
  files_group "root"
  files_mode 0o644
end

template "/usr/local/bin/expire-tiles" do
  source "expire-tiles.erb"
  owner "root"
  group "root"
  mode 0o755
end

directory "/var/lib/replicate" do
  owner "tile"
  group "tile"
  mode 0o755
end

directory "/var/lib/replicate/expire-queue" do
  owner "tile"
  group "www-data"
  mode 0o775
end

template "/var/lib/replicate/configuration.txt" do
  source "replicate.configuration.erb"
  owner "tile"
  group "tile"
  mode 0o644
end

template "/usr/local/bin/replicate" do
  source "replicate.erb"
  owner "root"
  group "root"
  mode 0o755
end

systemd_service "expire-tiles" do
  description "Tile dirtying service"
  type "simple"
  user "www-data"
  exec_start "/usr/local/bin/expire-tiles"
  standard_output "null"
  private_tmp true
  private_devices true
  protect_system "full"
  protect_home true
  no_new_privileges true
end

systemd_path "expire-tiles" do
  description "Tile dirtying trigger"
  directory_not_empty "/var/lib/replicate/expire-queue"
end

service "expire-tiles.path" do
  action [:enable, :start]
  subscribes :restart, "systemd_path[expire-tiles]"
end

systemd_service "replicate" do
  description "Rendering database replication service"
  after "postgresql.service"
  wants "postgresql.service"
  user "tile"
  exec_start "/usr/local/bin/replicate"
  private_tmp true
  private_devices true
  protect_system "full"
  protect_home true
  no_new_privileges true
  restart "on-failure"
end

service "replicate" do
  action [:enable, :start]
  subscribes :restart, "template[/usr/local/bin/replicate]"
  subscribes :restart, "systemd_service[replicate]"
end

template "/etc/logrotate.d/replicate" do
  source "replicate.logrotate.erb"
  owner "root"
  group "root"
  mode 0o644
end

template "/usr/local/bin/render-lowzoom" do
  source "render-lowzoom.erb"
  owner "root"
  group "root"
  mode 0o755
end

template "/etc/cron.d/render-lowzoom" do
  source "render-lowzoom.cron.erb"
  owner "root"
  group "root"
  mode 0o644
end

package "liblockfile-simple-perl"
package "libfilesys-df-perl"

template "/usr/local/bin/cleanup-tiles" do
  source "cleanup-tiles.erb"
  owner "root"
  group "root"
  mode 0o755
end

tile_directories = node[:tile][:styles].collect do |_, style|
  style[:tile_directories].collect { |directory| directory[:name] }
end.flatten.sort.uniq

template "/etc/cron.d/cleanup-tiles" do
  source "cleanup-tiles.cron.erb"
  owner "root"
  group "root"
  mode 0o644
  variables :directories => tile_directories
end

munin_plugin "mod_tile_fresh"
munin_plugin "mod_tile_latency"
munin_plugin "mod_tile_response"
munin_plugin "mod_tile_zoom"

munin_plugin "renderd_processed"
munin_plugin "renderd_queue"
munin_plugin "renderd_queue_time"
munin_plugin "renderd_zoom"
munin_plugin "renderd_zoom_time"

munin_plugin "replication_delay" do
  conf "munin.erb"
end
