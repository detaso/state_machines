# frozen_string_literal: true

require_relative 'options_validator'

module StateMachines
  # An event defines an action that transitions an attribute from one state to
  # another.  The state that an attribute is transitioned to depends on the
  # branches configured for the event.
  class Event
    include MatcherHelpers

    # The state machine for which this event is defined
    attr_accessor :machine

    # The name of the event
    attr_reader :name

    # The fully-qualified name of the event, scoped by the machine's namespace
    attr_reader :qualified_name

    # The human-readable name for the event
    attr_writer :human_name

    # The list of branches that determine what state this event transitions
    # objects to when fired
    attr_reader :branches

    # A list of all of the states known to this event using the configured
    # branches/transitions as the source
    attr_reader :known_states

    # Creates a new event within the context of the given machine
    #
    # Configuration options:
    # * <tt>:human_name</tt> - The human-readable version of this event's name
    def initialize(machine, name, options = nil, human_name: nil, **extra_options) # :nodoc:
      # Handle both old hash style and new kwargs style for backward compatibility
      if options.is_a?(Hash)
        # Old style: initialize(machine, name, {human_name: 'Custom Name'})
        StateMachines::OptionsValidator.assert_valid_keys!(options, :human_name)
        human_name = options[:human_name]
      else
        # New style: initialize(machine, name, human_name: 'Custom Name')
        raise ArgumentError, "Unexpected positional argument: #{options.inspect}" unless options.nil?

        StateMachines::OptionsValidator.assert_valid_keys!(extra_options, :human_name) unless extra_options.empty?
      end

      @machine = machine
      @name = name
      @qualified_name = machine.namespace ? :"#{name}_#{machine.namespace}" : name
      @human_name = human_name || @name.to_s.tr('_', ' ')
      reset

      # Output a warning if another event has a conflicting qualified name
      if (conflict = machine.owner_class.state_machines.detect { |_other_name, other_machine| other_machine != @machine && other_machine.events[qualified_name, :qualified_name] })
        _name, other_machine = conflict
        warn "Event #{qualified_name.inspect} for #{machine.name.inspect} is already defined in #{other_machine.name.inspect}"
      else
        add_actions
      end
    end

    # Creates a copy of this event in addition to the list of associated
    # branches to prevent conflicts across events within a class hierarchy.
    def initialize_copy(orig) # :nodoc:
      super
      @branches = @branches.dup
      @known_states = @known_states.dup
    end

    # Transforms the event name into a more human-readable format, such as
    # "turn on" instead of "turn_on"
    def human_name(klass = @machine.owner_class)
      @human_name.is_a?(Proc) ? @human_name.call(self, klass) : @human_name
    end

    # Evaluates the given block within the context of this event.  This simply
    # provides a DSL-like syntax for defining transitions.
    def context(&)
      instance_eval(&)
    end

    # Creates a new transition that determines what to change the current state
    # to when this event fires.
    #
    # Since this transition is being defined within an event context, you do
    # *not* need to specify the <tt>:on</tt> option for the transition.  For
    # example:
    #
    #  state_machine do
    #    event :ignite do
    #      transition :parked => :idling, :idling => same, :if => :seatbelt_on? # Transitions to :idling if seatbelt is on
    #      transition all => :parked, :unless => :seatbelt_on?                  # Transitions to :parked if seatbelt is off
    #    end
    #  end
    #
    # See StateMachines::Machine#transition for a description of the possible
    # configurations for defining transitions.
    def transition(options)
      raise ArgumentError, 'Must specify as least one transition requirement' if options.empty?

      # Only a certain subset of explicit options are allowed for transition
      # requirements
      StateMachines::OptionsValidator.assert_valid_keys!(options, :from, :to, :except_from, :except_to, :if, :unless) if (options.keys - %i[from to on except_from except_to except_on if unless]).empty?

      branches << branch = Branch.new(options.merge(on: name))
      @known_states |= branch.known_states
      branch
    end

    # Determines whether any transitions can be performed for this event based
    # on the current state of the given object.
    #
    # If the event can't be fired, then this will return false, otherwise true.
    #
    # *Note* that this will not take the object context into account.  Although
    # a transition may be possible based on the state machine definition,
    # object-specific behaviors (like validations) may prevent it from firing.
    def can_fire?(object, requirements = {})
      !transition_for(object, requirements).nil?
    end

    # Finds and builds the next transition that can be performed on the given
    # object.  If no transitions can be made, then this will return nil.
    #
    # Valid requirement options:
    # * <tt>:from</tt> - One or more states being transitioned from.  If none
    #   are specified, then this will be the object's current state.
    # * <tt>:to</tt> - One or more states being transitioned to.  If none are
    #   specified, then this will match any to state.
    # * <tt>:guard</tt> - Whether to guard transitions with the if/unless
    #   conditionals defined for each one.  Default is true.
    #
    # Event arguments are passed to guard conditions if they accept multiple parameters.
    def transition_for(object, requirements = {}, *event_args)
      StateMachines::OptionsValidator.assert_valid_keys!(requirements, :from, :to, :guard)
      requirements[:from] = machine.states.match!(object).name unless (custom_from_state = requirements.include?(:from))

      branches.each do |branch|
        next unless (match = branch.match(object, requirements, event_args))

        # Branch allows for the transition to occur
        from = requirements[:from]
        to = if match[:to].is_a?(LoopbackMatcher)
               from
             else
               values = requirements.include?(:to) ? [requirements[:to]].flatten : [from] | machine.states.map { |state| state.name }

               match[:to].filter(values).first
             end

        return Transition.new(object, machine, name, from, to, !custom_from_state)
      end

      # No transition matched
      nil
    end

    # Attempts to perform the next available transition on the given object.
    # If no transitions can be made, then this will return false, otherwise
    # true.
    #
    # Any additional arguments are passed to the StateMachines::Transition#perform
    # instance method.
    def fire(object, *event_args)
      machine.reset(object)

      if (transition = transition_for(object, {}, *event_args))
        transition.perform(*event_args)
      else
        on_failure(object, *event_args)
        false
      end
    end

    # Marks the object as invalid and runs any failure callbacks associated with
    # this event.  This should get called anytime this event fails to transition.
    def on_failure(object, *args)
      state = machine.states.match!(object)
      machine.invalidate(object, :state, :invalid_transition, [[:event, human_name(object.class)], [:state, state.human_name(object.class)]])

      transition = Transition.new(object, machine, name, state.name, state.name)
      transition.args = args if args.any?
      transition.run_callbacks(before: false)
    end

    # Resets back to the initial state of the event, with no branches / known
    # states associated.  This allows you to redefine an event in situations
    # where you either are re-using an existing state machine implementation
    # or are subclassing machines.
    def reset
      @branches = []
      @known_states = []
    end

    def draw(graph, options = {}, io = $stdout)
      machine.renderer.draw_event(self, graph, options, io)
    end

    # Generates a nicely formatted description of this event's contents.
    #
    # For example,
    #
    #   event = StateMachines::Event.new(machine, :park)
    #   event.transition all - :idling => :parked, :idling => same
    #   event   # => #<StateMachines::Event name=:park transitions=[all - :idling => :parked, :idling => same]>
    def inspect
      transitions = branches.flat_map do |branch|
        branch.state_requirements.map do |state_requirement|
          "#{state_requirement[:from].description} => #{state_requirement[:to].description}"
        end
      end.join(', ')

      "#<#{self.class} name=#{name.inspect} transitions=[#{transitions}]>"
    end

    protected

    # Add the various instance methods that can transition the object using
    # the current event
    def add_actions
      # Checks whether the event can be fired on the current object
      machine.define_helper(:instance, "can_#{qualified_name}?") do |machine, object, *args, **kwargs|
        machine.event(name).can_fire?(object, *args, **kwargs)
      end

      # Gets the next transition that would be performed if the event were
      # fired now
      machine.define_helper(:instance, "#{qualified_name}_transition") do |machine, object, *args, **kwargs|
        machine.event(name).transition_for(object, *args, **kwargs)
      end

      # Fires the event
      machine.define_helper(:instance, qualified_name) do |machine, object, *args, **kwargs|
        machine.event(name).fire(object, *args, **kwargs)
      end

      # Fires the event, raising an exception if it fails
      machine.define_helper(:instance, "#{qualified_name}!") do |machine, object, *args, **kwargs|
        object.send(qualified_name, *args, **kwargs) || raise(StateMachines::InvalidTransition.new(object, machine, name))
      end
    end
  end
end
