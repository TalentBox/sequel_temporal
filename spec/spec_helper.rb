require "sequel"
require "timecop"
DB = Sequel.sqlite
Dir[File.expand_path("../support/*.rb", __FILE__)].each{|f| require f}