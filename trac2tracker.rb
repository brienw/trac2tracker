#!/usr/bin/env ruby

require 'io/console'
require 'optparse'
require 'ruby-progressbar'
require 'sqlite3'
require 'pivotal-tracker'

trac_db = 'trac.db'
default_user = 'ezhou'

pt_project_id = ENV['PIVOTAL_PROJECT_ID'] ? ENV['PIVOTAL_PROJECT_ID'] : '821611'

if ENV['PIVOTAL_TOKEN']
  PivotalTracker::Client.token = ENV['PIVOTAL_TOKEN']
else
  unless pt_email
    print 'Pivotal email: '
    pt_email = gets.chomp
  end

  print 'Pivotal Password: '
  pt_password = STDIN.noecho(&:gets).chomp
  puts

  PivotalTracker::Client.token(pt_email, pt_password)
  puts "Authenticated as #{pt_email}"  
end

project = PivotalTracker::Project.find(pt_project_id)
if project
  puts "Found project '#{project.name}'"
else
  puts 'You do not appear to have permission to manage this project'
end

db = SQLite3::Database.new(trac_db)
puts 'Trac db loaded'

ticket_count = db.get_first_value('select count(*) from ticket')


memberships = (project.memberships.all).collect(&:name).map(&:downcase)
# TODO: verify memberships

story = nil
errors = 0
error_ids = []
comment_failures = []
ticket_progress = ProgressBar.create(:title => 'Tickets: ',
    :format => '%t %c/%C (%p%) |%b>>%i|', :total => ticket_count.to_i)

columns = nil

db.execute2('select * from ticket order by id desc') do |row_array|

  if columns.nil?
    columns = row_array
    next
  end
  row = {}
  columns.each_with_index do |name, index|
    row[name.to_sym] = row_array[index]
  end

  row[:status] ||= 'unscheduled'
  row[:owner] ||= default_user

  # translate statuses
  if row[:status] == 'closed' && %w(fixed duplicate wontfix invalid worksforme).include?(row[:resolution].chomp)
    row[:status] = 'accepted'
  elsif row[:status] == 'closed' && %w(readytotest reviewfix).include?(row[:resolution].chomp)
    row[:status] = 'delivered'
  elsif row[:status] == 'assigned'
    row[:status] = 'unstarted'
  elsif row[:status] == 'new'
    row[:status] = 'unscheduled'
  elsif row[:status] == 'reopened'
    row[:status] = 'rejected'
  end

  #translate types
  row[:type] = case row[:type]
                 when 'defect'; 'bug'
                 when 'enhancement'; 'feature'
                 when 'roadmap'; 'release'
                 when 'spec needed', 'task'; 'chore'
                 else row[:type]
               end

  if row[:type] == 'release' && row[:status] == 'delivered'
    row[:status] = 'accepted'
  end
  if row[:type] == 'chore' && row[:status] == 'delivered'
    row[:status] = 'accepted'
  end

  id = row[:id]
  story = row[:summary]
  labels = row[:milestone]
  story_type = row[:type]
  estimate = '1' #Why are we defaulting to the string '1', should it be nil or numeric?  Maybe only set it if the task is assigned?
  current_state = row[:status]
  requested_by = row[:reporter]
  owner = row[:owner]
  description = row[:description]

  unless memberships.include? requested_by.downcase
    # project.memberships.create(name: requested_by)
    memberships << requested_by.downcase
  end
  accepted_at = Time.at(row[:changetime]) if row[:status] == 'accepted'
  # bugs and releases can't have estimate
  estimate = nil if %w(bug release chore).include? story_type

  # update progress bar with new ticket id
  ticket_progress.title = "Ticket #{id}"
  begin
    story = project.stories.create(
        name: story,
        labels: labels,
        story_type: story_type,
        estimate: estimate,
        current_state: current_state,
        created_at: Time.at(row[:time]),
        accepted_at: accepted_at,
        # requested_by: requested_by,
        # owner: owner,
        description: description.chomp + "\n[trac#{id}] Imported from trac, original id #{id}"
    )

  if story.errors.count > 0
    puts "Failed on ticket #{id}"
    puts story.errors
    errors = errors + 1
    error_ids << id
  else
    # migrate comments
    begin
      db.execute(query = 'select newvalue from ticket_change where field=="comment" and newvalue != \'\' and ticket=' + id.to_s + ' and newvalue !=' + id.to_s) do |comment|
        story.notes.create(:text => comment[0]) unless comment[0].empty?
      end
    rescue
      puts "failed adding comments to ticket #{id}"
      comment_failures << id
    end
    ticket_progress.increment
  end
  rescue
#    puts $!.backtrace
    puts "Failed on ticket: #{id}"
  end

end
puts "\nErrors: #{errors}" if errors > 0
puts "Ticket IDs: " + error_ids.join(',') if error_ids.length > 0
puts "failed adding comments to: " + comment_failures.join(',') if comment_failures.length > 0
