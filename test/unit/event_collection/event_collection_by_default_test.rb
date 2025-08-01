# frozen_string_literal: true

require 'test_helper'

class EventCollectionByDefaultTest < StateMachinesTest
  def setup
    @klass = Class.new
    @machine = StateMachines::Machine.new(@klass)
    @events = StateMachines::EventCollection.new(@machine)
    @object = @klass.new
  end

  def test_should_not_have_any_nodes
    assert_equal 0, @events.length
  end

  def test_should_have_a_machine
    assert_equal @machine, @events.machine
  end

  def test_should_not_have_any_valid_events_for_an_object
    assert_empty @events.valid_for(@object)
  end

  def test_should_not_have_any_transitions_for_an_object
    assert_empty @events.transitions_for(@object)
  end
end
