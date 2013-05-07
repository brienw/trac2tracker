#!/usr/bin/env ruby

require 'io/console'
require 'optparse'
require 'ruby-progressbar'
require 'sqlite3'
require 'pivotal-tracker'

trac_db = 'trac.db'
default_user = 'ezhou'

# pt_project_id = '784261' # CPF spt
pt_project_id = '820749' # CPF Test
#pt_project_id = '820865' # matt's CPF Test
pt_email = 'brien@reebosak.net'

unless ENV['PIVOTAL_TOKEN']
  unless pt_email
    print 'Pivotal email: '
    pt_email = gets.chomp
  end

  print 'Pivotal Password: '
  pt_password = STDIN.noecho(&:gets).chomp
  puts

  unless pt_project_id
    puts "\nPivotal Project ID: "
    pt_project_id = gets.chomp
  end

  PivotalTracker::Client.token(pt_email, pt_password)
  puts "Authenticated as #{pt_email}"
else
  PivotalTracker::Client.token = ENV['PIVOTAL_TOKEN']
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

  if row[:status].nil?
    row[:status] = 'unscheduled'
  end
  if row[:owner].nil?
    row[:owner] = default_user
  end

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
                 when 'defect'
                   'bug'
                 when 'enhancement'
                   'feature'
                 when 'roadmap'
                   'release'
                 when 'spec needed', 'task'
                   'chore'
                 else
                   row[:type]
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
  estimate = '1'
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
  rescue
    puts $!.backtrace
    puts "Ticket: #{id}"
    binding.pry
  end
  # # migrate comments
  # db.execute(query = 'select newvalue from ticket_change where field=="comment" and newvalue != \'\' and ticket=' + id.to_s + ' and newvalue !=' + id.to_s) do |comment|
  #   story.notes.create(:text => comment[0]) unless comment[0].empty?
  # end
  if story.errors.count > 0
    puts "Failed on ticket #{id}"
    puts story.errors
    binding.pry
    errors = errors + 1
  else
    ticket_progress.title = "Ticket #{id}"
    ticket_progress.increment
  end
end
puts "Errors: #{errors}"