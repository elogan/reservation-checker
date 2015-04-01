#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'

require 'aws-sdk'
require 'json'
require 'terminal-table'
require 'yaml'

config = YAML.load_file('config.yml')

def check_ec2(config, reservations, instances)
  config['regions'].each do |region|
    connection = AWS::EC2.new(
      access_key_id: config['access_key_id'],
      secret_access_key: config['secret_access_key'],
      region: region)

    connection.reserved_instances.select { |x| x.state == 'active' }.each do |ri|
      type = 'ec2:' + ri.instance_type + ':' + ri.availability_zone
      reservations[type] += ri.instance_count
    end

    connection.instances.select { |x| x.status == :running }.each do |i|
      type = 'ec2:' + i.instance_type + ':' + i.availability_zone
      instances[type] += 1
    end
  end
end

def check_elasticache(config, reservations, instances)
  config['regions'].each do |region|
    connection = AWS::ElastiCache.new(
      access_key_id: config['access_key_id'],
      secret_access_key: config['secret_access_key'],
      region: region)

    connection.client.describe_reserved_cache_nodes.data[:reserved_cache_nodes].each do |i|
      next unless i[:state] == 'active'
      type = 'elasticache:' + i[:product_description] + ':' + i[:cache_node_type]
      type << ':' << region
      reservations[type] += 1
    end

    connection.client.describe_cache_clusters.data[:cache_clusters].each do |i|
      next unless i[:cache_cluster_status] == 'available'

      type = 'elasticache:' + i[:engine] + ':' + i[:cache_node_type]
      type += ':' + region
      instances[type] += 1
    end
  end
end

def check_rds(config, reservations, instances)
  config['regions'].each do |region|
    connection = AWS::RDS.new(
      access_key_id: config['access_key_id'],
      secret_access_key: config['secret_access_key'],
      region: region)

    connection.client.describe_reserved_db_instances.data[:reserved_db_instances].each do |i|
      type = 'rds:' + i[:product_description] + ':' + i[:db_instance_class]
      type += '-multi_az' if i[:multi_az]
      type += ':' + region
      reservations[type.gsub('postgresql', 'postgres')] += i[:db_instance_count]
    end

    connection.client.describe_db_instances.data[:db_instances].each do |i|
      type = 'rds:' + i[:engine] + ':' + i[:db_instance_class]
      type += '-multi_az' if i[:multi_az]
      type += ':' + region
      instances[type] += 1
    end
  end
end

def check_redshift(config, reservations, instances)
  config['regions'].each do |region|
    connection = AWS::Redshift.new(
      access_key_id: config['access_key_id'],
      secret_access_key: config['secret_access_key'],
      region: region)

    connection.client.describe_reserved_nodes.data[:reserved_nodes].each do |i|
      type = 'redshift:' + i[:node_type]
      type += ':' + region
      reservations[type] += i[:node_count]
    end

    connection.client.describe_clusters.data[:clusters].
      select { |i| i[:cluster_status] == 'available' }.each do |i|

      type = 'redshift:' + i[:node_type]
      type += ':' + region
      instances[type] += i[:number_of_nodes]
    end
  end
end

AWS.memoize do

  reservations = Hash.new(0)
  instances = Hash.new(0)

  check_ec2(config, reservations, instances) if config['products'].include? 'ec2'
  check_elasticache(config, reservations, instances) if config['products'].include? 'elasticache'
  check_rds(config, reservations, instances) if config['products'].include? 'rds'
  check_redshift(config, reservations, instances) if config['products'].include? 'redshift'

  unused_reservations = reservations.clone
  unreserved_instances = instances.clone

  instances.each do |type, count|
    unused_reservations[type] -= count
    unused_reservations[type] = 0 if unused_reservations[type] < 0
  end

  reservations.each do |type, count|
    unreserved_instances[type] -= count
    unreserved_instances[type] = 0 if unreserved_instances[type] < 0
  end

  table = Terminal::Table.new(headings: ['Type', 'Unused Reservations',
                                         'Unreserved Units',
                                         'Total Reservations', 'Total Units'])

  types = instances.keys + reservations.keys
  types.uniq.sort.each do |type|
    table.add_row [type,
                   unused_reservations[type],
                   unreserved_instances[type],
                   reservations[type],
                   instances[type]]
  end

  puts table
end
