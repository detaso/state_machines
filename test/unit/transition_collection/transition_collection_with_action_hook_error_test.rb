# frozen_string_literal: true

require 'test_helper'
require_relative 'transition_collection_with_action_hook_base_test'

class TransitionCollectionWithActionHookErrorTest < TransitionCollectionWithActionHookBaseTest
  def setup
    super

    @superclass.class_eval do
      remove_method :save

      def save
        raise ArgumentError
      end
    end

    begin
      StateMachines::TransitionCollection.new([@transition]).perform
    rescue StandardError
    end
  end

  def test_should_not_write_event
    assert_nil @object.state_event
  end

  def test_should_not_write_event_transition
    assert_nil @object.send(:state_event_transition)
  end
end
