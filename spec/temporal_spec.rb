require "spec_helper"

describe "Sequel::Plugins::Temporal" do
  before :all do
    DB.drop_table(:room_versions) if DB.table_exists?(:room_versions)
    DB.drop_table(:rooms) if DB.table_exists?(:rooms)
    DB.create_table! :rooms do
      primary_key :id
    end
    DB.create_table! :room_versions do
      primary_key :id
      foreign_key :master_id, :rooms
      String      :name
      Fixnum      :price
      Date        :created_at
      Date        :expired_at
    end
    @version_class = Class.new Sequel::Model do
      set_dataset :room_versions
      def validate
        super
        errors.add(:name, "is required") unless name
        errors.add(:price, "is required") unless price
      end
    end
    closure = @version_class
    @master_class = Class.new Sequel::Model do
      set_dataset :rooms
      plugin :temporal, version_class: closure
    end
  end
  before do
    Timecop.freeze 2009, 11, 28
    @version_class.truncate
    @master_class.truncate
  end
  after do
    Timecop.return
  end
  it "checks version class is given" do
    lambda{
      @version_class.plugin :temporal
    }.should raise_error Sequel::Error, "please specify version class to use for temporal plugin"
  end
  it "checks required columns are present" do
    lambda{
      @version_class.plugin :temporal, version_class: @master_class
    }.should raise_error Sequel::Error, "temporal plugin requires the following missing columns on version class: master_id, created_at, expired_at"
  end
  it "propagates errors from version to master" do
    master = @master_class.new
    master.should be_valid
    master.attributes = {name: "Single Standard"}
    master.should_not be_valid
    master.errors.should == {price: ["is required"]}
  end
  it "#update_attributes returns false instead of raising errors" do
    master = @master_class.new
    master.update_attributes(name: "Single Standard").should be_false
    master.should be_new
    master.errors.should == {price: ["is required"]}
    master.update_attributes(price: 98).should be_true
  end
  it "allows creating a master and its first version in one step" do
    master = @master_class.new
    master.update_attributes(name: "Single Standard", price: 98).should be_true
    master.should_not be_new
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | current |
      | Single Standard | 98    | 2009-11-28 |            | true    |
    }
  end
  it "doesn't loose previous version in same-day update" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes name: "Single Standard", price: 94
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 |         |
      | Single Standard | 94    | 2009-11-28 |            | true    |
    }
  end
  it "allows partial updating based on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    master.update_attributes price: 94, partial_update: true
    master.update_attributes name: "King Size", partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-28 |         |
      | Single Standard | 94    | 2009-11-28 | 2009-11-28 |         |
      | King Size       | 94    | 2009-11-28 |            | true    |
    }
  end
  it "expires previous version but keep it in history" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.update_attributes price: 94, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 |            | true    |
    }
  end
  xit "doesn't do anything if unchanged" do
  end
  it "allows deleting current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.destroy.should be_true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 |         |
    }
  end
  it "allows simultaneous updates without information loss" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master2 = @master_class.find id: master.id
    master.update_attributes name: "Single Standard", price: 94
    master2.update_attributes name: "Single Standard", price: 95
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 | 2009-11-29 |         |
      | Single Standard | 95    | 2009-11-29 |            | true    |
    }
  end
  it "allows simultaneous cumulative updates" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master2 = @master_class.find id: master.id
    master.update_attributes price: 94, partial_update: true
    master2.update_attributes name: "King Size", partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 | 2009-11-29 |         |
      | King Size       | 94    | 2009-11-29 |            | true    |
    }
  end
  it "allows eager loading with conditions on current version" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    @master_class.eager_graph(:current_version).where("rooms_current_version.id IS NOT NULL").first.should be
    Timecop.freeze Date.today+1
    master.destroy
    @master_class.eager_graph(:current_version).where("rooms_current_version.id IS NOT NULL").first.should be_nil
  end
  it "allows loading masters with a current version" do
    master_destroyed = @master_class.new
    master_destroyed.update_attributes name: "Single Standard", price: 98
    master_destroyed.destroy
    master_with_current = @master_class.new
    master_with_current.update_attributes name: "Single Standard", price: 94
    @master_class.with_current_version.all.should have(1).item
  end
  it "gets pending or current version attributes" do
    master = @master_class.new
    master.attributes.should == {}
    master.pending_version.should be_nil
    master.pending_or_current_version.should be_nil
    master.update_attributes name: "Single Standard", price: 98
    master.attributes[:name].should == "Single Standard"
    master.pending_version.should be_nil
    master.pending_or_current_version.name.should == "Single Standard"
    master.attributes = {name: "King Size"}
    master.attributes[:name].should == "King Size"
    master.pending_version.should be
    master.pending_or_current_version.name.should == "King Size"
  end
  it "allows to go back in time" do
    master = @master_class.new
    master.update_attributes name: "Single Standard", price: 98
    Timecop.freeze Date.today+1
    master.update_attributes price: 94, partial_update: true
    master.should have_versions %Q{
      | name            | price | created_at | expired_at | current |
      | Single Standard | 98    | 2009-11-28 | 2009-11-29 |         |
      | Single Standard | 94    | 2009-11-29 |            | true    |
    }
    master.current_version.price.should == 94
    Sequel::Plugins::Temporal.at(Date.today-1) do
      master.current_version(true).price.should == 98
    end
  end
  it "delegates attributes from master to pending_or_current_version" do
    master = @master_class.new
    master.name.should be_nil
    master.update_attributes name: "Single Standard", price: 98
    master.name.should == "Single Standard"
    master.attributes = {name: "King Size", partial_update: true}
    master.name.should == "King Size"
  end
  it "avoids delegation with option delegate: false" do
    closure = @version_class
    without_delegation_class = Class.new Sequel::Model do
      set_dataset :rooms
      plugin :temporal, version_class: closure, delegate: false
    end
    master = without_delegation_class.new
    expect{ master.name }.to raise_error NoMethodError
  end
  it "get current_version association name from class name" do
    class MyNameVersion < Sequel::Model
      set_dataset :room_versions
    end
    class MyName < Sequel::Model
      set_dataset :rooms
      plugin :temporal, version_class: MyNameVersion
    end
    expect do
      MyName.eager_graph(:current_version).where("my_name_current_version.id IS NOT NULL").first
    end.not_to raise_error
    Object.send :remove_const, :MyName
    Object.send :remove_const, :MyNameVersion
  end
end
