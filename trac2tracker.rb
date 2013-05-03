#!/usr/bin/env ruby

require 'io/console'
require 'rubygems'
require 'pivotal-tracker'
# require 'cinch'
# require 'daemons'
# require 'yaml'

print "Pivotal Email: "
pt_username = gets.chomp
print "Pivotal Password: "
pt_password = STDIN.noecho(&:gets).chomp
print "\nPivotal Project ID: "
pt_project_id = gets.chomp

PivotalTracker::Client.token(gh_username, gh_password)
project = PivotalTracker::Project.find(gh_project_id)

