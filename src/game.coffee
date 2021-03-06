wrap_angle = (ang) ->
    return ((ang + Math.PI) %% (2 * Math.PI)) - Math.PI

sign = (x) -> if x == 0 then 0 else x / Math.abs(x)

infill_object = (dest, src) ->
    for key, val of src
        if key not of dest
            dest[key] = val
    return dest

# Standard vector class for geo
class Vector
    constructor: (@x, @y) ->

    # Standard ops
    plus: (o) -> new Vector @x + o.x, @y + o.y
    minus: (o) -> new Vector @x - o.x, @y - o.y
    times: (s) -> new Vector @x * s, @y * s
    divided_by: (s) -> new Vector @x / s, @y / s
    magnitude: -> Math.sqrt @x * @x + @y * @y
    unit: -> @divided_by @magnitude()
    dir: -> Math.atan2 @y, @x
    copy: (o) -> @x = o.x; @y = o.y
    clone: -> new Vector @x, @y

    # In-place ops
    plus_inplace: (o) -> @x += o.x; @y += o.y; return
    minus_inplace: (o) -> @x -= o.x; @y -= o.y; return
    times_inplace: (s) -> @x *= s; @y *= s; return
    divided_by_inplace: (s) -> @x /= s; @y /= s; return
    unit_inplace: -> @divided_by_inplace @magnitude()

Vector.fromPolar = (magnitude, angle) ->
    new Vector Math.cos(angle) * magnitude, Math.sin(angle) * magnitude

# RenderContexts know about canvases and contexts
class RenderContext
    constructor: (@canvas, @ctx) ->
        @stone_asset = @ctx.createPattern(document.getElementById('stone-asset'), 'repeat')
        @stone_top_asset = @ctx.createPattern(document.getElementById('stone-top-asset'), 'repeat')

class AiWorker
    constructor: (@character, program) ->
        blob = new Blob [program], {type: 'text/javascript'}
        @worker = new Worker URL.createObjectURL blob
        @ready = true

        @worker.onmessage = (e) =>
            e = e.data
            switch e.type
                when 'ready'
                    @ready = true
                when 'turn'
                    @character.angular_dir = e.dir
                when 'move'
                    @character.movement_dir = e.dir
                    @character.moving = true
                when 'strike'
                    @character.strike()
                when 'start_shooting'
                    @character.start_shooting()
                when 'stop_shooting'
                    @character.stop_shooting()
                when 'nock'
                    @character.nock()
                when 'loose'
                    @character.loose()
                when 'cast'
                    @character.cast new Vector e.target.x, e.target.y
                when 'cancel_casting'
                    @character.cancel_casting()

    tick: (info) ->
        if @ready
            @worker.postMessage {
                characters: info.characters.filter((x) => x.health > 0 and x isnt @character).map (x) => x.create_reader(@character.allegiance)
                bullets: info.bullets.filter((x) -> x.alive).map (x) -> x.create_reader()
                spells: info.spells.filter((x) -> x.alive).map (x) -> x.create_reader()
                walls: info.walls.map (x) -> x.create_reader()
                main_character: @character.create_reader(@character.allegiance)
            }

            @ready = false

    terminate: -> @worker.terminate()

# Every Character is a cylinder with a height and a radius.
class Character
    constructor: (@height, @radius, @pos = new Vector(0, 0), @allegiance, @ai = DUMBO, @colors = {}) ->
        @velocity = new Vector(0, 0)
        @hitbox_radius = @radius * 1.5

        @ai_runner = new AiWorker @, create_ai_from_template @ai
        @player_controlled = false

        infill_object @colors, DEFAULT_COLORS

        @dir = 0
        @age = 0

        @movement_dir = null
        @moving = false
        @walking_acceleration = 0.3

        @angular_dir = 0
        @angular_velocity = 0
        @angular_acceleration = 0.03

        @health = @max_health = 100

    create_reader: (allegiance) -> {
        @pos,
        @dir,
        @velocity,
        @angular_velocity,
        @health,
        @player_controlled,
        allegiance: @allegiance is allegiance,
        class: @type_string
    }

    damage: (damage) ->
        @health -= damage
        @health = Math.max @health, 0

    tick: (info) ->
        unless @player_controlled
            @ai_runner.tick info

        @age += 1

        # Velocity
        if @moving
            @velocity.plus_inplace Vector.fromPolar @walking_acceleration, @movement_dir

        @angular_velocity *= ANGULAR_FRICTION
        @angular_velocity += @angular_acceleration * Math.max -1, Math.min 1, @angular_dir
        @dir += @angular_velocity
        @dir = wrap_angle(@dir)

        @pos.plus_inplace @velocity
        @velocity.times_inplace FRICTION

        return

    # Pos is our position on the ground,
    # but many UI interactions instead want to deal with
    # our heart location, in the middle of our torso
    heart: ->
        @pos.minus new Vector(0, @height * 3 / 4)

    render_pants: (render_context) ->
        {ctx, canvas} = render_context

        # Our legs are the same height as our torso.
        pants_height = @height * (1 - TORSO_PROPORTION)
        right_pants_height = pants_height
        left_pants_height = pants_height

        # If we are walking, our legs are different
        # heights
        if @moving
            # Determine our parity
            if Math.floor(@age / WALKING_PERIOD) % 2 is 0
                right_pants_height *= WALKING_RATIO
            else
                left_pants_height *= WALKING_RATIO

        # Legs take up exactly half of the linear area
        # of our bottom, so they are each 1/2 radius in width.
        pants_width = @radius / 2

        # @pos it the center of our bottom.
        # This means our pants centers are at:
        right_leg_center = @pos.minus new Vector(pants_width, pants_height)
        left_leg_center = @pos.minus new Vector(-pants_width, pants_height)

        # Pants color
        ctx.strokeStyle = @colors.pants
        ctx.lineWidth = pants_width
        ctx.lineCap = 'round'

        # Draw the rectangles
        ctx.beginPath()
        ctx.moveTo right_leg_center.x, right_leg_center.y
        ctx.lineTo right_leg_center.x, right_leg_center.y + right_pants_height
        ctx.stroke()

        ctx.beginPath()
        ctx.moveTo left_leg_center.x, left_leg_center.y
        ctx.lineTo left_leg_center.x, left_leg_center.y + left_pants_height
        ctx.stroke()

    render_torso: (render_context) ->
        {ctx, canvas} = render_context

        torso_height = @height * TORSO_PROPORTION
        torso_width = @radius * 2

        # Corner is the top-right of our entire hitbox
        torso_corner = @pos.minus new Vector(@radius, @height)
        torso_bottom_center = @pos.minus new Vector(0, @height - torso_height)
        torso_top_center = @pos.minus new Vector(0, @height)

        ctx.fillStyle = @colors.torso

        ctx.fillRect(
            torso_corner.x,
            torso_corner.y,
            torso_width,
            torso_height
        )

        ctx.beginPath()
        ctx.arc(
            torso_bottom_center.x,
            torso_bottom_center.y,
            @radius,
            0,
            2 * Math.PI
        )
        ctx.fill()

        ctx.fillStyle = @colors.torso_top

        ctx.beginPath()
        ctx.arc(
            torso_top_center.x,
            torso_top_center.y,
            @radius,
            0,
            2 * Math.PI
        )
        ctx.fill()

    left_arm_vector: ->
        return Vector.fromPolar(@height * 0.3, @dir).plus(
            new Vector(0, @height / 4)
        )

    right_arm_vector: ->
        return Vector.fromPolar(@height * 0.3, @dir).plus(
            new Vector(0, @height / 4)
        )

    render_left_item: ->
    render_right_item: ->

    # Arms and torso are grouped together
    # so that arms can control when the torso is drawn.
    # This is so that one arm can appear to be "behind"
    # the body for appropriate directions.
    render_arms_and_torso: (render_context) ->
        {ctx, canvas} = render_context

        arm_center = @pos.minus new Vector(0, @height)

        # Determine which arm is "behind"
        right_arm = arm_center.plus Vector.fromPolar(@radius, @dir + Math.PI / 2)
        left_arm = arm_center.plus Vector.fromPolar(@radius, @dir - Math.PI / 2)

        # Determine the hand positions
        right_arm_dest = right_arm.plus @right_arm_vector()
        left_arm_dest = left_arm.plus @left_arm_vector()

        if right_arm.y < left_arm.y
            back_arm = right_arm
            back_arm_dest = right_arm_dest
            front_arm = left_arm
            front_arm_dest = left_arm_dest
        else
            back_arm = left_arm
            back_arm_dest = left_arm_dest
            front_arm = right_arm
            front_arm_dest = right_arm_dest

        # Draw the "behind" item
        if Math.sin(@dir) < 0 #right_arm_dest.y < @pos.y
            if left_arm is back_arm
                @render_left_item(render_context, left_arm_dest)
                @render_right_item(render_context, right_arm_dest)
            else
                @render_right_item(render_context, right_arm_dest)
                @render_left_item(render_context, left_arm_dest)
        #if left_arm_dest.y < @pos.y

        # Draw the "behind" arm
        ctx.strokeStyle = @colors.arms
        ctx.lineWidth = @radius / 2
        ctx.lineCap = 'round'

        ctx.beginPath()
        ctx.moveTo back_arm.x, back_arm.y
        ctx.lineTo back_arm_dest.x, back_arm_dest.y
        ctx.stroke()

        # Draw torso and head
        @render_torso(render_context)
        @render_head(render_context)

        # Draw the "in front" arm
        ctx.strokeStyle = @colors.arms
        ctx.lineWidth = @radius / 2
        ctx.lineCap = 'round'

        ctx.beginPath()
        ctx.moveTo front_arm.x, front_arm.y
        ctx.lineTo front_arm_dest.x, front_arm_dest.y
        ctx.stroke()

        # Draw "front" item
        if Math.sin(@dir) >= 0 #right_arm_dest.y >= @pos.y
            if left_arm is back_arm
                @render_left_item(render_context, left_arm_dest)
                @render_right_item(render_context, right_arm_dest)
            else
                @render_right_item(render_context, right_arm_dest)
                @render_left_item(render_context, left_arm_dest)

    render_hat: ->

    render_head: (render_context) ->
        {ctx, canvas} = render_context

        head_center = @pos.minus new Vector(0, @height + @radius)

        ctx.fillStyle = @colors.head

        ctx.beginPath()
        ctx.arc(
            head_center.x,
            head_center.y,
            @radius,
            0,
            2 * Math.PI
        )
        ctx.fill()

        #@render_hat render_context, head_center

    render_shadow: (render_context) ->
        {ctx, canvas} = render_context

        ctx.globalAlpha = 0.5

        ctx.fillStyle = '#000'
        ctx.beginPath()
        ctx.arc(
            @pos.x, @pos.y,
            @hitbox_radius,
            0, 2 * Math.PI
        )
        ctx.fill()

        ctx.globalAlpha = 1

    render: (render_context) ->
        @render_shadow(render_context)
        @render_pants(render_context)
        @render_arms_and_torso(render_context)
        @render_health_bar(render_context)
        @render_emblem(render_context)

    render_health_bar: (render_context) ->
        {ctx, canvas} = render_context

        pos = @pos.minus new Vector(@hitbox_radius, @height + @radius + 20)

        ctx.fillStyle = '#F00'
        ctx.fillRect(
            pos.x, pos.y, 3 * @radius, 5
        )

        ctx.fillStyle = '#0F0'
        ctx.fillRect(
            pos.x, pos.y, 3 * @radius * @health / @max_health, 5
        )

    render_emblem: (render_context) ->
        {ctx, canvas} = render_context

        center = @pos.minus new Vector @hitbox_radius, @height + @radius + 20 - 2.5

        if @allegiance
            ctx.fillStyle = '#FFF'
        else
            ctx.fillStyle = '#000'

        ctx.beginPath()
        ctx.arc(center.x, center.y, 5, 0, 2 * Math.PI)
        ctx.fill()

        if @player_controlled
            ctx.fillStyle = '#0F0'
        else if @allegiance
            ctx.fillStyle = '#00F'
        else
            ctx.fillStyle = '#F00'
        ctx.beginPath()
        ctx.moveTo center.x, center.y + 5
        for x in [1..3]
            point = center.plus Vector.fromPolar 5, x * Math.PI * 2 / 3 + Math.PI / 2
            ctx.lineTo point.x, point.y
        ctx.fill()

class Knight extends Character
    constructor: ->
        super

        @type = Knight
        @type_string = 'knight'

        @strike_age = 0
        @striking_forward = false
        @striking_sidways = false

        @walking_acceleration = 0.2
        @angular_acceleration = 0.04

        @colors.torso = '#78A'
        @colors.torso_top = '#568'
        @colors.head = '#AAF'

        @health = @max_health = 100

    create_reader: ->
        reader = super
        reader.strike_age = @strike_age
        reader.striking_forward = @striking_forward
        reader.striking_sideways = @striking_sideways
        return reader

    damage: (damage) ->
        if @striking_sidweays
            @health -= damage
        else if @striking_forward
            @health -= damage / 2
        else
            @health -= damage / 6

    tick: ->
        super

        if @striking_forward and @age - @strike_age > 10
            @striking_forward = false
            @striking_sideways = true

        if @striking_sideways and @age - @strike_age > 60
            @striking_sideways = false

    left_arm_vector: ->
        if @striking_sideways
            return Vector.fromPolar(@height * 0.3, -Math.PI / 4 * Math.min(1, (@age - @strike_age - 10) / 5) + @dir).plus(
                new Vector(0, @height / 4)
            )
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    right_arm_vector: ->
        if @striking_forward
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4 * (1 - (@age - @strike_age) / 10))
            )
        else if @striking_sideways
            return Vector.fromPolar(@height * 0.3, @dir + Math.min(1, (@age - @strike_age - 10) / 5) * Math.PI / 2)
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    # Shield
    render_left_item: (render_context, position) ->
        {ctx, canvas} = render_context

        # Shield is a rectangle
        shield_width = @radius * 2
        shield_height = @height * SHIELD_RATIO

        shield_top_center = position.minus new Vector 0, shield_height / 2
        shield_starting_point = shield_top_center.minus Vector.fromPolar shield_width / 2, @dir + Math.PI / 2

        corners = [
            shield_starting_point,
            shield_starting_point.plus(Vector.fromPolar(shield_width, @dir + Math.PI / 2)),
            shield_starting_point.plus(Vector.fromPolar(shield_width, @dir + Math.PI / 2)).plus(new Vector(0, shield_height)),
            shield_starting_point.plus(new Vector(0, shield_height))
        ]

        ctx.fillStyle = '#555'
        ctx.strokeStyle = '#888'
        ctx.lineWidth = 2
        ctx.lineJoin = 'bevel'
        ctx.beginPath()
        ctx.moveTo(corners[0].x, corners[0].y)
        for corner in corners
            ctx.lineTo corner.x, corner.y
        ctx.lineTo(corners[0].x, corners[0].y)
        ctx.fill()
        ctx.stroke()

    # Sword
    render_right_item: (render_context, position) ->
        {ctx, canvas} = render_context

        # Sword is a line
        if @striking_forward
            sword_dest = position.plus(new Vector(0, -@height/2 * (1 - (@age - @strike_age) / 10))).plus(
                Vector.fromPolar(@radius + 1.5 * (@age - @strike_age) / 10 * @radius, @dir)
            )
        else if @striking_sideways
            sword_dest = position.plus(
                Vector.fromPolar(@radius * 2.5, @dir + Math.min(1, (@age - @strike_age - 10) / 5) * Math.PI / 2)
            )
        else
            sword_dest = position.plus(new Vector(0, -@height/2)).plus(
                Vector.fromPolar(@radius, @dir)
            )

        ctx.strokeStyle = '#999'
        ctx.lineWidth = 5
        ctx.beginPath()
        ctx.moveTo(position.x, position.y)
        ctx.lineTo(sword_dest.x, sword_dest.y)
        ctx.stroke()

    strike: ->
        unless @striking_forward or @striking_sideways
            @strike_age = @age
            @striking_forward = true

SPELL_RADIUS = 100
class Particle
    constructor: (center, gen_proportion) ->
        @pos = center.plus Vector.fromPolar Math.random() * SPELL_RADIUS * gen_proportion, Math.random() * 2 * Math.PI
        @radius = ((Math.random() + 0.5) * 10 + 10) * gen_proportion
        @height = 0
        @speed = Math.random() * 10
        @age = 0

        @r = 255
        @g = 255
        @b = 255

    tick: ->
        @age += 1
        @height += @speed

        @r *= (0.95 + Math.random() * 0.05)
        @g *= 0.8
        @b *= 0.5

    render: (render_context) ->
        {ctx, canvas} = render_context
        ctx.fillStyle = "rgb(#{Math.round(@r)}, #{Math.round(@g)}, #{Math.round(@b)})"
        ctx.beginPath()
        ctx.arc(@pos.x, @pos.y - @height, @radius / Math.sqrt(@age), 0, 2 * Math.PI)
        ctx.fill()

class Spell
    constructor: ->
        @pos = null
        @age = 0
        @burning = false
        @alive = false
        @orientation = 0
        @particles = []

    create_reader: -> {@pos, @age, @burning}

    reset: (position) ->
        @pos = position
        @age = 0
        @alive = true
        @burning = false
        @orientation = Math.random() * 2 * Math.PI
        @particles = []

    tick: ->
        return unless @alive
        @age += 1

        if @age > 270
            @alive = false
            @burning = false
        else if @age > 90
            @burning = true
            @particles.forEach (p) -> if p.radius / Math.sqrt(p.age) > 4 then p.tick()
            age_proportion = Math.sqrt 1 - (@age - 90) / 180
            for [1...Math.floor((Math.random() * 4 + 3) * age_proportion)]
                @particles.push new Particle(@pos, age_proportion)

    render: (render_context) ->
        return unless @alive

        {ctx, canvas} = render_context

        ctx.strokeStyle = '#F00'
        ctx.lineWidth = 2
        ctx.beginPath()
        ctx.arc(@pos.x, @pos.y, SPELL_RADIUS, 0, 2 * Math.PI)

        # Pentagram
        if @burning
            ctx.globalAlpha = 0.8 * (1 - (@age - 90) / 180)
            ctx.fillStyle = '#000'
            ctx.fill()

            ctx.globalAlpha = 0.8
            for particle in @particles
                if particle.radius / Math.sqrt(particle.age) > 4
                    particle.render render_context
            ctx.globalAlpha = 1
        else
            ctx.stroke()
            ctx.beginPath()
            new_pos = @pos.plus(Vector.fromPolar(SPELL_RADIUS, @orientation))
            ctx.moveTo new_pos.x, new_pos.y

            proportion = @age / 90
            limit = Math.floor proportion * 6
            excess = proportion * 6 - limit

            for i in [0..limit]
                new_pos = @pos.plus(Vector.fromPolar(SPELL_RADIUS, i * Math.PI * 4 / 5 + @orientation))
                ctx.lineTo new_pos.x, new_pos.y

            # Last one
            last_point = @pos.plus(Vector.fromPolar(SPELL_RADIUS, limit * Math.PI * 4 / 5 + @orientation))
            next_point = @pos.plus(Vector.fromPolar(SPELL_RADIUS, (limit + 1) * Math.PI * 4 / 5 + @orientation))

            excess_point = last_point.times(1 - excess).plus(next_point.times(excess))
            ctx.lineTo excess_point.x, excess_point.y

            ctx.stroke()

class Mage extends Character
    constructor: ->
        super

        @type = Mage
        @type_string = 'mage'

        @colors.torso = '#53F'
        @colors.torso_top = '#217'
        @colors.arms = @colors.pants = '#217'

        @walking_acceleration = 0.15
        @angular_acceleration = 0.01

        @casting = false
        @casting_age = 0

        @spell = new Spell()

    damage: ->
        super
        if @health <= 0
            @spell.alive = false

    tick: ->
        super

        if @casting and not @spell.alive
            @casting = false
            @walking_acceleration = 0.15

        return

    create_reader: ->
        reader = super
        reader.casting = @casting
        reader.casting_age = @casting_age
        return reader

    cast: (position) ->
        if @spell.burning or @casting or @health <= 0 then return

        @casting = true
        @casting_age = @age
        @walking_acceleration = 0

        @spell.reset position

        return @spell

    cancel_casting: ->
        @casting = false
        @walking_acceleration = 0.15
        unless @spell.burning
            @spell.alive = false

    left_arm_vector: ->
        if @casting
            proportion = Math.min 1, (@age - @casting_age) / 60

            return Vector.fromPolar(@height * 0.3 * (1 - proportion), @dir).plus(
                new Vector(0, @height * (0.25 + 0.25 * proportion))
            )
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    render_hat: (render_context, position) ->
        {ctx, canvas} = render_context

        ctx.fillStyle = '#006'
        left = position.plus(new Vector(-@radius - 1, 0))
        right = position.plus(new Vector(@radius + 1, 0))
        top = position.minus(new Vector(0, @radius * 3))

        ctx.beginPath()
        ctx.arc top.x, top.y, top.minus(left).magnitude(), right.minus(top).dir(), left.minus(top).dir()
        ctx.lineTo top.x, top.y
        ctx.fill()

    right_arm_vector: ->
        if @casting
            proportion = Math.min 1, (@age - @casting_age) / 60
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height * (0.25 - 0.5 * proportion))
            )
        else
            super

    render_right_item: (render_context, position) ->
        top_position = position.minus(new Vector(0, @height / 2))
        bottom_position = position.plus(new Vector(0, @height / 2))

        {canvas, ctx} = render_context

        ctx.strokeStyle = 'brown'
        ctx.lineWidth = 5

        ctx.beginPath()
        ctx.moveTo top_position.x, top_position.y
        ctx.lineTo bottom_position.x, bottom_position.y
        ctx.stroke()

        ctx.fillStyle = 'red'
        ctx.beginPath()
        ctx.arc(top_position.x, top_position.y, 5, 0, 2 *Math.PI)
        ctx.fill()

BOW_HEIGHT = 20
BOW_COLOR = 'brown'
BOWSTRING_COLOR = 'white'
BOW_THICKNESS = 5
ARROW_VELOCITY = 10
ARROW_LENGTH = 25
class Archer extends Character
    constructor: ->
        super

        @type = Archer
        @type_string = 'archer'

        @loading = false
        @loaded = false
        @loading_age = 0

        @bullet_to_return = null

        @colors.torso = 'green'
        @colors.torso_top = 'darkgreen'
        @colors.arms = @colors.pants = 'goldenrod'

    create_reader: ->
        reader = super
        reader.loading = @loading
        reader.loaded = @loaded
        reader.loading_age = @loading_age
        reader.ready_to_shoot = (@age - @loading_age > 90 and @loaded)
        return reader

    tick: ->
        super

        if @loading and @age - @loading_age > 30
            @loading = false
            @loaded = true

        if @bullet_to_return
            bullet = @bullet_to_return
            @bullet_to_return = null
            return bullet

    nock: ->
        unless @loading or @loaded
            @loading = true
            @loading_age = @age
            @walking_acceleration = 0.15

    loose: ->
        @loading = false
        @walking_acceleration = 0.3

        if @age - @loading_age > 90 and @loaded
            @loaded = false
            @bullet_to_return = new Bullet(
                @pos.plus(Vector.fromPolar(@radius + ARROW_LENGTH / 2, @dir)),
                Vector.fromPolar(ARROW_VELOCITY, @dir),
                @height,
                ARROW_LENGTH,
                90,
                'brown',
                50
            )
        @loaded = false
        return

    render_hat: (render_context, position) ->
        {ctx, canvas} = render_context

        ctx.fillStyle = 'darkgreen'
        left = position.plus(new Vector(-@radius - 2, -2))
        right = position.plus(new Vector(@radius + 2, -2))
        top = position.minus(new Vector(0, @radius * 1.5))

        ctx.beginPath()
        ctx.arc top.x, top.y, top.minus(left).magnitude(), right.minus(top).dir(), left.minus(top).dir()
        ctx.lineTo top.x, top.y
        ctx.fill()

    right_arm_vector: ->
        if @loading
            proportion = Math.min(1, (@age - @loading_age) / 30)

            return Vector.fromPolar(@height * (0.3 + 0.1 * proportion), @dir).plus(
                new Vector(0, @height / 4 * (1 - proportion))
            ).plus(
                Vector.fromPolar(@radius * proportion, @dir - Math.PI / 2)
            )
        else if @loaded
            proportion = Math.min(1, (@age - @loading_age - 30) / 60)
            return Vector.fromPolar(@height * 0.4 * (1 - proportion), @dir).plus(
                Vector.fromPolar(@radius * (1 - proportion), @dir - Math.PI / 2)
            )
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    left_arm_vector: ->
        if @loading or @loaded
            proportion = Math.min(1, (@age - @loading_age) / 30)

            return Vector.fromPolar(@height * (0.3 + 0.1 * proportion), @dir).plus(
                new Vector(0, @height / 4 * (1 - proportion))
            ).plus(
                Vector.fromPolar(@radius * proportion, @dir + Math.PI / 2)
            )
        else
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4)
            )

    render_left_item: (render_context, position) ->
        {canvas, ctx} = render_context

        if @loaded
            proportion = Math.min(1, (@age - @loading_age - 30) / 60)
            top_dest = position.minus(new Vector(0, BOW_HEIGHT)).minus(Vector.fromPolar(5 * (1 + proportion), @dir))
            bottom_dest = position.plus(new Vector(0, BOW_HEIGHT)).minus(Vector.fromPolar(5 * (1 + proportion), @dir))
        else
            top_dest = position.minus(new Vector(0, BOW_HEIGHT)).minus(Vector.fromPolar(5, @dir))
            bottom_dest = position.plus(new Vector(0, BOW_HEIGHT)).minus(Vector.fromPolar(5, @dir))

        ctx.strokeStyle = BOW_COLOR
        ctx.lineWidth = BOW_THICKNESS

        # Bow itself
        ctx.beginPath()
        ctx.moveTo top_dest.x, top_dest.y
        ctx.lineTo position.x, position.y
        ctx.lineTo bottom_dest.x, bottom_dest.y
        ctx.stroke()

class Bullet
    constructor: (@pos, @velocity, @height, @length, @lifetime, @color, @damage = 5) ->
        @alive = true
        @age = 0

    create_reader: -> {@pos, @velocity, @height, @length, @lifetime, @age, @damage}

    tick: ->
        unless @alive then return

        @age += 1
        @pos.plus_inplace @velocity

        if @age > @lifetime
            @alive = false

        return

    render: (render_context) ->
        unless @alive then return

        {ctx, canvas} = render_context

        ctx.strokeStyle = @color
        ctx.lineWidth = 5

        begin = @pos.minus Vector.fromPolar @length / 2, @velocity.dir()
        end = @pos.plus Vector.fromPolar @length / 2, @velocity.dir()

        ctx.beginPath()
        ctx.moveTo begin.x, begin.y - @height
        ctx.lineTo end.x, end.y - @height
        ctx.stroke()

        ctx.strokeStyle = '#000'
        ctx.lineWidth = 5
        ctx.globalAlpha = 0.5

        ctx.beginPath()
        ctx.moveTo begin.x, begin.y
        ctx.lineTo end.x, end.y
        ctx.stroke()

        ctx.globalAlpha = 1

DAGGER_LENGTH = 10
DAGGER_COLOR = '#888'
DAGGER_LIFETIME = 10
DAGGER_VELOCITY = 2
class Rogue extends Character
    constructor: ->
        super

        @type = Rogue
        @type_string = 'rogue'

        @shooting = false
        @last_shot = 0

        @colors.arms = @colors.pants = '#440'
        @colors.torso = '#550'
        @colors.torso_top = '#220'

        @walking_acceleration = 0.5

    create_reader: ->
        reader = super
        reader.shooting = @shooting
        reader.last_shot = @last_shot
        return reader

    tick: ->
        super

        if @shooting and @age - @last_shot > 10
            @last_shot = @age
            return new Bullet(
                @pos.plus(Vector.fromPolar(@radius * 2 + DAGGER_LENGTH, @dir)),
                Vector.fromPolar(DAGGER_VELOCITY, @dir),
                @height / 2,
                DAGGER_LENGTH,
                DAGGER_LIFETIME,
                DAGGER_COLOR,
                10
            )
        return

    start_shooting: ->
        @shooting = true

    stop_shooting: ->
        @shooting = false

    right_arm_vector: ->
        if @shooting
            return Vector.fromPolar(@height * 0.3, @dir).plus(
                new Vector(0, @height / 4 * (1 - (@age - @last_shot) / 10))
            )
        else
            super

WALL_HEIGHT = 50
class Wall
    constructor: (@pos, @width, @height) ->

    create_reader: -> {@pos, @width, @height}

    render: (render_context) ->
        {ctx, canvas, stone_asset, stone_top_asset} = render_context

        ctx.fillStyle = stone_asset
        ctx.fillRect @pos.x, @pos.y + @height - WALL_HEIGHT, @width, WALL_HEIGHT

        ctx.fillStyle = stone_top_asset
        ctx.fillRect @pos.x, @pos.y - WALL_HEIGHT, @width, @height

allied_positions = [
    new Vector(50, 50)
    new Vector(50, 100)
    new Vector(100, 50)
    new Vector(100, 100)
]
instantiate_character = (template, index, allegiance) ->
    if allegiance
        index_positions = allied_positions
    else
        index_positions = allied_positions.map (x) -> new Vector(BOARD_WIDTH, BOARD_HEIGHT).minus x

    switch template.class
        when 'Mage'
            return new Mage(
                50,
                10,
                index_positions[index].clone(),
                allegiance,
                template.ai
            )
        when 'Knight'
            return new Knight(
                50,
                10,
                index_positions[index].clone(),
                allegiance,
                template.ai
            )
        when 'Rogue'
            return new Rogue(
                50,
                10,
                index_positions[index].clone(),
                allegiance,
                template.ai
            )
        when 'Archer'
            return new Archer(
                50,
                10,
                index_positions[index].clone(),
                allegiance,
                template.ai
            )

BOARD_HEIGHT = 750
BOARD_WIDTH = 1500

character_templates = [0, 0, 0, 0]
enemy_templates = [0, 0, 0, 0]

keysdown = {}

document.body.addEventListener 'keydown', (event) ->
    keysdown[event.which] = true

document.body.addEventListener 'keyup', (event) ->
    keysdown[event.which] = false

# MAIN RUNTIME
play_game = (enemy_name, enemies) ->
    document.getElementById('play-screen').style.display = 'block'
    document.getElementById('main-menu').style.display = 'none'
    document.getElementById('edit-screen').style.display = 'none'

    document.getElementById('other-name').innerText = generate_name enemy_name
    document.getElementById('self-name').innerText = generate_name CURRENT_USER.uid

    for i in [0...4]
        document.getElementById("self-#{i + 1}").style.backgroundImage =
            "url(#{IMAGE_URLS[SCRIPTS[character_templates[i]].class]})"
        document.getElementById("other-#{i + 1}").style.backgroundImage =
            "url(evil-#{IMAGE_URLS[enemies[i].type_string]})"

    canvas = document.getElementById 'viewport'
    ctx = canvas.getContext '2d'
    render_context = new RenderContext canvas, ctx

    canvas.width = canvas.clientWidth
    canvas.height = canvas.clientHeight

    # Draw none-sign
    none_canvas = document.getElementById('spectate-canvas')
    none_ctx = none_canvas.getContext '2d'

    none_ctx.resetTransform()
    none_ctx.clearRect 0, 0, none_canvas.width, none_canvas.height
    none_ctx.translate none_canvas.width / 2, none_canvas.height / 2
    none_ctx.rotate Math.PI / 4

    none_ctx.strokeStyle = '#F00'
    none_ctx.lineWidth = 5
    none_ctx.beginPath()
    none_ctx.arc(0, 0, 20, 0, 2 * Math.PI)
    none_ctx.moveTo(20, 0)
    none_ctx.lineTo(-20, 0)
    none_ctx.stroke()

    # Draw white flag
    quit_canvas = document.getElementById('quit-canvas')
    quit_ctx = quit_canvas.getContext '2d'

    quit_ctx.clearRect 0, 0, quit_canvas.width, quit_canvas.height
    quit_ctx.fillStyle = '#FFF'
    quit_ctx.fillRect 15, 10, 30, 20
    quit_ctx.fillStyle = 'brown'
    quit_ctx.fillRect 10, 10, 5, 50

    # Create the board
    tile_width = canvas.width / 40
    tile_height = canvas.height / 20

    characters = character_templates.map (x, i) -> instantiate_character SCRIPTS[x], i, true
    characters = characters.concat enemies

    # Display countdown covering
    countdown_covering = document.getElementById('countdown-screen')
    countdown_number = document.getElementById('countdown-number')
    countdown_covering.style.display = 'block'

    should_continue_tick = true

    main_character = null

    bullets = []
    walls = [
        new Wall(new Vector(300, 500), 700, 30)
    ]

    # Dirt asset
    dirt_asset = ctx.createPattern(document.getElementById('dirt-asset'), 'repeat')

    # Symmetry
    new_walls = []
    for wall in walls
        new_walls.push wall
        new_walls.push new Wall(
            new Vector(
                BOARD_WIDTH - (wall.pos.x + wall.width),
                BOARD_HEIGHT - (wall.pos.y + wall.height)
            ),
            wall.width,
            wall.height
        )
    walls = new_walls

    grass_spots = [1..Math.floor(Math.random() * 20 + 10)].map ->
        new Vector(Math.random() * (BOARD_WIDTH - 100), Math.random() * (BOARD_HEIGHT - 100))
    grass_asset = document.getElementById('grass-asset')

    translate_vector = new Vector(0, 0)

    spells = characters.filter((x) -> x instanceof Mage).map((x) -> x.spell)

    char_listeners = []

    for i in [1..4] then do (i) ->
        document.getElementById("char-#{i}").addEventListener 'click', char_listeners[i] = ->
            if main_character
                main_character.player_controlled = false
            main_character = characters[i - 1]
            main_character.player_controlled = true

            rerender_ingame_selects()

    document.getElementById('spectate').addEventListener 'click', spectate_listener = ->
        if main_character
            main_character.player_controlled = false
        main_character = null

    document.getElementById('quit').addEventListener 'click', quit_listener = ->
        should_continue_tick = false
        terminate()
        do lose_screen

    desired_pos = new Vector(canvas.width / 2, canvas.height / 2)

    canvas.addEventListener 'mousemove', mousemove_listener = (event) ->
        desired_pos = new Vector event.offsetX, event.offsetY

    moving_target = null

    canvas.oncontextmenu = (e) -> e.preventDefault(); return false

    # Do one render pass
    # Draw the board
    ctx.fillStyle = dirt_asset #'#faa460'
    ctx.fillRect 0, 0, BOARD_WIDTH, BOARD_HEIGHT

    for spot in grass_spots
        ctx.drawImage grass_asset, spot.x, spot.y

    # Draw the stuffs on the board
    entities = characters.concat(walls).sort (a, b) -> if a.pos.y > b.pos.y then return 1 else return -1
    for entity in entities when (not entity.health?) or entity.health > 0
        entity.render render_context

    canvas.addEventListener 'mousedown', mousedown_handler = (event) ->
        if event.which is 3
            moving_target = new Vector(event.offsetX, event.offsetY).minus(translate_vector)
            event.preventDefault()
            return false

        if main_character instanceof Knight
            main_character.strike()
        else if main_character instanceof Archer
            main_character.nock()
        else if main_character instanceof Rogue
            main_character.start_shooting()
        else if main_character instanceof Mage
            main_character.cast new Vector(event.offsetX, event.offsetY).minus(translate_vector)

    document.body.addEventListener 'mouseup', mouseup_handler = (event) ->
        if main_character instanceof Archer
            result = main_character.loose()
            if result then bullets.push result
        else if main_character instanceof Rogue
            main_character.stop_shooting()
        else if main_character instanceof Mage
            main_character.cancel_casting()

    # Remove all event handlers
    terminate = ->
        canvas.removeEventListener 'mousedown', mousedown_handler
        canvas.removeEventListener 'mouseup', mouseup_handler

        for i in [1..4] then do (i) ->
            document.getElementById("char-#{i}").removeEventListener 'click', char_listeners[i]

        document.getElementById('spectate').removeEventListener 'click', spectate_listener
        document.getElementById('quit').removeEventListener 'click', quit_listener


    contexts = [1..4].map (i) ->
        small_canvas = document.getElementById("canvas-#{i}")
        small_ctx = small_canvas.getContext '2d'

        return new RenderContext small_canvas, small_ctx

    rerender_ingame_selects = ->
        for context, i in contexts
            context.ctx.resetTransform()
            context.ctx.clearRect 0, 0, context.canvas.width, context.canvas.height
            if characters[i].health <= 0
                context.canvas.style.opacity = '0.3'
            else
                context.canvas.style.opacity = '1'
            context.ctx.translate -characters[i].pos.x + context.canvas.width / 2, -characters[i].pos.y + characters[i].height + 35

            characters[i].render context

    do rerender_ingame_selects

    # Countdown to the start of the game
    countdown = (secs) ->
        if secs > 0
            countdown_number.innerText = secs.toString()
            setTimeout (-> countdown secs - 1), 1000
            return

        countdown_covering.style.display = 'none'

        tick = ->
            # Move the camera
            if desired_pos.x < 50
                translate_vector.x += Math.sqrt(50 - desired_pos.x)
            if desired_pos.x > canvas.width - 50
                translate_vector.x -= Math.sqrt(desired_pos.x - (canvas.width - 50))
            if desired_pos.y < 50
                translate_vector.y += Math.sqrt(50 - desired_pos.y)
            if desired_pos.y > canvas.height - 50
                translate_vector.y -= Math.sqrt(desired_pos.y - (canvas.height - 50))

            do rerender_ingame_selects

            # Edges
            translate_vector.x = -Math.max -50, Math.min BOARD_WIDTH + 50 - canvas.width, -translate_vector.x
            translate_vector.y = -Math.max -50, Math.min BOARD_HEIGHT + 50 - canvas.height, -translate_vector.y

            # Check win condition
            if characters.filter((x) -> x.health > 0 and x.allegiance).length == 0
                characters.forEach (x) -> x.ai_runner.terminate()
                terminate()
                return lose_screen()
            else if characters.filter((x) -> x.health > 0 and not x.allegiance).length == 0
                characters.forEach (x) -> x.ai_runner.terminate()
                terminate()
                return win_screen()
            else if should_continue_tick
                setTimeout tick, 1000 / FRAME_RATE

            ctx.resetTransform()

            ctx.clearRect 0, 0, canvas.width, canvas.height

            if main_character
                desired_dir = desired_pos.minus(translate_vector)
                    .minus(main_character.pos.minus(new Vector(0, main_character.height))).dir()

                normalized_delta = wrap_angle(desired_dir - main_character.dir)
                main_character.angular_dir = 10 * normalized_delta / Math.PI

                prototype_vector = new Vector(0, 0)
                main_character.moving = false

                if keysdown[key_codes.w]
                    main_character.moving = true
                    prototype_vector.y -= 1
                if keysdown[key_codes.s]
                    main_character.moving = true
                    prototype_vector.y += 1
                if keysdown[key_codes.a]
                    main_character.moving = true
                    prototype_vector.x -= 1
                if keysdown[key_codes.d]
                    main_character.moving = true
                    prototype_vector.x += 1

                if main_character.moving
                    main_character.movement_dir = prototype_vector.dir()

            ctx.translate(translate_vector.x, translate_vector.y)

            # Draw the board
            ctx.fillStyle = dirt_asset #'#faa460'
            ctx.fillRect 0, 0, BOARD_WIDTH, BOARD_HEIGHT

            for spot in grass_spots
                ctx.drawImage grass_asset, spot.x, spot.y

            for spell in spells
                spell.tick()
                spell.render render_context

            for character in characters when character.health > 0
                # Detect spell intersection.
                # Spells do damage every frame.
                for spell in spells
                    if spell.alive and spell.burning and character.pos.minus(spell.pos).magnitude() < SPELL_RADIUS
                        character.damage 1

                # Detect character intersection for knights
                if character.striking_sideways
                    for target in characters when target isnt character and character.health > 0
                        if character.pos.minus(target.pos).magnitude() < character.radius * 4 + target.radius and
                                Math.abs(wrap_angle(target.pos.minus(character.pos).dir() - character.dir)) < Math.PI / 2
                            target.damage 3

                result = character.tick {characters, walls, spells, bullets}

                # Detect edge intersection
                if character.pos.x < character.hitbox_radius then character.pos.x = character.hitbox_radius
                if character.pos.x > BOARD_WIDTH - character.hitbox_radius then character.pos.x = BOARD_WIDTH - character.hitbox_radius

                if character.pos.y < character.hitbox_radius then character.pos.y = character.hitbox_radius
                if character.pos.y > BOARD_HEIGHT - character.hitbox_radius then character.pos.y = BOARD_HEIGHT - character.hitbox_radius

                # Detect wall intersection
                for wall in walls
                    # Running into a wall; we have a problem
                    if wall.pos.x < character.pos.x + character.hitbox_radius and
                            character.pos.x - character.hitbox_radius < wall.pos.x + wall.width and
                            wall.pos.y < character.pos.y + character.hitbox_radius and
                            character.pos.y - character.hitbox_radius < wall.pos.y + wall.height

                        # Pop us to one side of the rectangle
                        bottom_intersect = new Vector(
                            character.pos.x,
                            wall.pos.y + wall.height + character.hitbox_radius
                        )
                        top_intersect = new Vector(
                            character.pos.x,
                            wall.pos.y - character.hitbox_radius
                        )
                        right_intersect = new Vector(
                            wall.pos.x + wall.width + character.hitbox_radius,
                            character.pos.y
                        )
                        left_intersect = new Vector(
                            wall.pos.x - character.hitbox_radius,
                            character.pos.y
                        )

                        # Find the closest one and send us there.
                        distances = [bottom_intersect, top_intersect, right_intersect, left_intersect].map (p) ->
                            p.minus(character.pos).magnitude()

                        min_dist = Math.min.apply window, distances

                        if min_dist is distances[0]
                            character.pos.copy bottom_intersect
                            continue
                        if min_dist is distances[1]
                            character.pos.copy top_intersect
                            continue
                        if min_dist is distances[2]
                            character.pos.copy right_intersect
                            continue
                        if min_dist is distances[3]
                            character.pos.copy left_intersect
                            continue

                if result
                    bullets.push result

            entities = characters.concat(walls).sort (a, b) -> if a.pos.y > b.pos.y then return 1 else return -1
            for entity in entities when (not entity.health?) or entity.health > 0
                entity.render render_context

            new_bullets = []
            for bullet in bullets
                bullet.tick()
                bullet.render render_context

                # Detect character intersection
                for character in characters when character.health > 0
                    if bullet.pos.minus(character.pos).magnitude() < character.hitbox_radius
                        character.damage bullet.damage
                        bullet.alive = false
                        continue

                for wall in walls
                    if wall.pos.x < bullet.pos.x < wall.pos.x + wall.width and wall.pos.y < bullet.pos.y < wall.pos.y + wall.height
                        bullet.alive = false
                        continue

                if bullet.alive
                    new_bullets.push bullet

            bullets = new_bullets

        tick()

    countdown 3

create_ai_from_template = (program) ->
    return """
    var me;

    function wrap_angle(ang) {
        return (((ang + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI)) - Math.PI
    }

    function Vector(x, y) {
        this.x = x;
        this.y = y;
    }

    Vector.prototype.plus = function(o) {
        return new Vector(this.x + o.x, this.y + o.y);
    };

    Vector.prototype.minus = function(o) {
        return new Vector(this.x - o.x, this.y - o.y);
    };

    Vector.prototype.times = function(s) {
        return new Vector(this.x * s, this.y * s);
    };

    Vector.prototype.divided_by = function(s) {
        return new Vector(this.x / s, this.y / s);
    };

    Vector.prototype.magnitude = function() {
        return Math.sqrt(this.x * this.x + this.y * this.y);
    };

    Vector.prototype.dir_to = function(other) {
        if (other.pos) other = other.pos;
        return other.minus(this).dir();
    }

    Vector.prototype.distance = function(other) {
        if (other.pos) other = other.pos;
        return this.minus(other).magnitude();
    }

    Vector.prototype.unit = function() {
      return this.divided_by(this.magnitude());
    };

    Vector.prototype.dir = function() {
      return Math.atan2(this.y, this.x);
    };

    function move(dir) {
        postMessage({type: 'move', dir: dir})
    }
    function move_toward(pos) {
        postMessage({type: 'move', dir: me.dir_to(pos)});
    }
    function turn(dir) {
        postMessage({type: 'turn', dir: dir})
    }
    function turn_to(dir) {
        normalized_delta = wrap_angle(dir - me.dir);
        turn(10 * normalized_delta / Math.PI);
    }
    function turn_toward(pos) {
        var desired_dir = me.dir_to(pos);
        turn_to(desired_dir)
    }
    function strike() {
        postMessage({type: 'strike'})
    }
    function start_shooting() {
        postMessage({type: 'start_shooting'})
    }
    function stop_shooting() {
        postMessage({type: 'stop_shooting'})
    }
    function nock() {
        postMessage({type: 'nock'})
    }
    function loose() {
        postMessage({type: 'loose'})
    }
    function cast(target) {
        postMessage({type: 'cast', target: target})
    }
    function cancel_casting() {
        postMessage({type: 'cancel_casting'})
    }

    function unpack(obj) {
        if (obj.pos) {
            obj.pos = new Vector(obj.pos.x, obj.pos.y)
            obj.distance = function(x) { return obj.pos.distance(x); };
            obj.dir_to = function(x) { return obj.pos.dir_to(x); };
        }
        if (obj.velocity) {
            obj.velocity = new Vector(obj.velocity.x, obj.velocity.y)
        }
        return obj;
    }

    function closest_among(various) {
        var min_dist = Infinity;
        var closest = null;
        for (var i = 0; i < various.length; i++) {
            var candidate_dist = me.distance(various[i]);
            if (candidate_dist < min_dist) {
                min_dist = candidate_dist;
                closest = various[i];
            }
        }
        return closest;
    }

    var _characters, _bullets, _spells, _walls, _enemies, _allies;

    function characters() {
        return _characters;
    }
    function bullets() {
        return _bullets;
    }
    function walls() {
        return _walls;
    }
    function spells() {
        return _spells;
    }
    function enemies() {
        return _enemies;
    }
    function allies() {
        return _allies;
    }

    onmessage = function(e) {
        var info = e.data;
        _characters = info.characters.map(unpack);
        _bullets = info.bullets.map(unpack);
        _spells = info.spells.map(unpack);
        _walls = info.walls.map(unpack);

        _enemies = _characters.filter(function(x) { return !x.allegiance; });
        _allies = _characters.filter(function(x) { return x.allegiance; });

        me = unpack(info.main_character);

        (function() {
        #{program}
        }());

        postMessage({type: 'ready'})
    }
"""

DUMBO = '''
    if (Math.random() < 1 / 60) {
        direction = Math.random() * 2 * Math.PI;
        move(direction);
    }
'''

ROGUE_AI = '''
    // Basic Rogue AI; chases and shoots at enemies.
    var target = closest_among(enemies());
    turn_toward(target);
    move_toward(target);
    start_shooting();'''

KNIGHT_AI = '''
    // Basic Knight AI; chases and hits enemies.
    var target = closest_among(enemies());
    turn_toward(target);
    move_toward(target);
    if (me.distance(target) <= 55) {
        strike();
    }'''

MAGE_AI = '''
    // Basic Rogue AI; casts spells at enemies.
    var target = closest_among(enemies());
    cast(target.pos);'''

ARCHER_AI = '''
    // Basic Archer AI; shoots at enemies.
    var target = closest_among(enemies());
    turn_toward(target);
    if (me.ready_to_shoot) {
        loose();
    }
    else {
        nock();
    }'''

DEFAULT_COLORS = {
    pants: 'black'
    torso: 'chocolate'
    torso_top: 'brown'
    arms: 'black'
    head: 'tan'
}

NECK_HEIGHT = 10
FRICTION = 0.8
ANGULAR_FRICTION = 0.5
TORSO_PROPORTION = 0.4

key_codes = {
    w: 87,
    s: 83,
    a: 65,
    d: 68
}

FRAME_RATE = 60 #100
WALKING_PERIOD = 50
WALKING_RATIO = 0.7
SHIELD_RATIO = 0.7

class Script
    constructor: (@name, @class, @ai) ->

SCRIPTS = [
    new Script('Basic', 'Mage', MAGE_AI),
    new Script('Basic', 'Knight', KNIGHT_AI),
    new Script('Basic', 'Archer', ARCHER_AI),
    new Script('Basic', 'Rogue', ROGUE_AI)
]

database = firebase.database()

# Load scripts from the database once
load_scripts = ->
    database.ref("/scripts/#{CURRENT_USER.uid}").once('value').then (snapshot) ->
        if snapshot.val() == null
            SCRIPTS = [
                new Script('Basic', 'Mage', MAGE_AI),
                new Script('Basic', 'Knight', KNIGHT_AI),
                new Script('Basic', 'Archer', ARCHER_AI),
                new Script('Basic', 'Rogue', ROGUE_AI)
            ]
        else
            SCRIPTS = snapshot.val().map (x) -> new Script x[0], x[1], x[2]

        ace_editor.setValue SCRIPTS[character_templates[currently_editing]].ai, -1
        do update_prototype_list

load_settings = ->
    database.ref("/settings/#{CURRENT_USER.uid}").once('value').then (snapshot) ->
        val = snapshot.val()
        character_templates = val?.character_templates ? [0, 0, 0, 0]
        enemy_templates = val?.enemy_templates ? [0, 0, 0, 0]
        ace_editor.setValue SCRIPTS[character_templates[currently_editing]].ai, -1
        do rerender_tabs
        do rerender_enemy_tabs

'''
ARCHETYPES = {
    'Mage': new Mage(50, 10, new Vector(25, 85), false)
    'Archer': new Archer(50, 10, new Vector(25, 85), false)
    'Knight': new Knight(50, 10, new Vector(25, 85), false)
    'Rogue': new Rogue(50, 10, new Vector(25, 85), false)
}
'''

win_screen = ->
    document.getElementById('win-screen').style.display = 'block'

lose_screen = ->
    document.getElementById('lose-screen').style.display = 'block'

main_menu = ->
    document.getElementById('play-screen').style.display = 'none'
    document.getElementById('win-screen').style.display = 'none'
    document.getElementById('edit-screen').style.display = 'none'
    document.getElementById('lose-screen').style.display = 'none'
    document.getElementById('main-menu').style.display = 'block'
    document.getElementById('signin').style.display = 'none'
    document.getElementById('registration').style.display = 'none'
    document.getElementById('main-menu-floater').style.display = 'block'

login_screen = ->
    document.getElementById('play-screen').style.display = 'none'
    document.getElementById('win-screen').style.display = 'none'
    document.getElementById('edit-screen').style.display = 'none'
    document.getElementById('lose-screen').style.display = 'none'
    document.getElementById('main-menu').style.display = 'block'
    document.getElementById('signin').style.display = 'block'
    document.getElementById('registration').style.display = 'none'
    document.getElementById('main-menu-floater').style.display = 'none'

registration_screen = ->
    document.getElementById('play-screen').style.display = 'none'
    document.getElementById('win-screen').style.display = 'none'
    document.getElementById('edit-screen').style.display = 'none'
    document.getElementById('lose-screen').style.display = 'none'
    document.getElementById('main-menu').style.display = 'block'
    document.getElementById('signin').style.display = 'none'
    document.getElementById('registration').style.display = 'block'
    document.getElementById('main-menu-floater').style.display = 'none'

# Edit screen
edit_element = document.getElementById 'edit-editor'
edit_element.oncontextmenu = (event) -> event.stopPropagation()
ace_editor = new droplet.Editor edit_element, {
    mode: 'javascript',
    viewSettings: {
        padding: 10,
        textPadding: 5,
        colors: {
            value: "#94c096",
            assign: "#f3a55d",
            declaration: "#f3a55d",
            type: "#f3a55d",
            control: "#ecc35b",
            function: "#b593e6",
            functionCall: "#889ee3",
            logic: "#6fc2eb",
            struct: "#f58c4f",
            return: "#b593e6"
        }
    },
    modeOptions: {
        functions: {
            'closest_among': {
                color: 'value'
                value: 'true'
            },
            'turn_toward': {
                color: 'command'
            },
            'turn_to': {
                color: 'command'
            },
            'turn': {
                color: 'command'
            },
            'move': {
                color: 'command'
            },
            'move_toward': {
                color: 'command'
            },
            'start_shooting': {
                color: 'command'
            },
            'stop_shooting': {
                color: 'command'
            },
            'strike': {
                color: 'command'
            },
            'cast': {
                color: 'command'
            },
            'nock': {
                color: 'command'
            },
            'loose': {
                color: 'command'
            },
            '*.distance': {
                color: 'value'
                value: true
            }
            '*.dir_to': {
                color: 'value'
                value: true
            }
            '*.minus': {
                color: 'value'
                value: true
            }
            '*.plus': {
                color: 'value'
                value: true
            }
            '*.magnitude': {
                color: 'value'
                value: true
            }
            '*.dir': {
                color: 'value'
                value: true
            }
            '*.health': {
                color: 'value'
                value: true
            }
            '*.pos': {
                color: 'value'
                value: true
            }
            'enemies': {
                color: 'value'
                value: true
            }
            'allies': {
                color: 'value'
                value: true
            }
            'bullets': {
                color: 'value'
                value: true
            }
            'spells': {
                color: 'value'
                value: true
            }
            '*.times': {
                color: 'value'
                value: true
            }
            '*.filter': {
                color: 'value'
                value: true
            }
            '*.push': {
                color: 'command'
            }
            'wrap_angle': {
                color: 'value'
                value: true
            }
            '*.map': {
                color: 'value'
                value: true
            }
        }
    }
    palette: [
        {
            name: 'Control'
            color: 'orange'
            blocks: [
                {
                    block: 'if (condition) {\n  \n}'
                }
                {
                    block: 'if (condition) {\n  \n} else {\n  \n}'
                }
                {
                    block: 'for (var i = 0; i < n; i++) {\n  \n}'
                }
                {
                    block: 'while (condition) {\n  \n}'
                }
                {
                    block: 'return;'
                }
            ]
        }
        {
            name: 'Math'
            color: 'blue'
            blocks: [
                {
                    block: 'a + b'
                }
                {
                    block: 'a - b'
                }
                {
                    block: 'a * b'
                }
                {
                    block: 'a / b'
                }
                {
                    block: 'a > b'
                }
                {
                    block: 'a >= b'
                }
                {
                    block: 'a == b'
                }
                {
                    block: 'a <= b'
                }
                {
                    block: 'a < b'
                }
                {
                    block: 'a && b'
                }
                {
                    block: 'a || b'
                }
                {
                    block: '!a'
                }
            ]
        }
        {
            name: 'Vectors'
            color: 'green'
            blocks: [
                {
                    block: 'v.plus(u)'
                }
                {
                    block: 'v.minus(u)'
                }
                {
                    block: 'v.times(s)'
                }
                {
                    block: 'v.dir()'
                }
                {
                    block: 'v.magnitude()'
                }
                {
                    block: 'v.dir_to(u)'
                }
                {
                    block: 'v.distance(u)'
                }
                {
                    block: 'wrap_angle(x)'
                }
            ]
        }
        {
            name: 'Sensing'
            color: 'red'
            blocks: [
                {
                    block: 'closest_among(list)'
                }
                {
                    block: 'enemies()'
                }
                {
                    block: 'allies()'
                }
                {
                    block: 'bullets()'
                }
                {
                    block: 'spells()'
                }
                {
                    block: 'walls()'
                }
                {
                    block: 'me.health'
                }
                {
                    block: 'me.dir'
                }
                {
                    block: 'me.pos'
                }
            ]
        }
        {
            name: 'Commands'
            color: 'purple'
            blocks: [
                {
                    block: 'turn_toward(x);'
                }
                {
                    block: 'turn_to(dir);'
                }
                {
                    block: 'turn(dir);'
                }
                {
                    block: 'move(dir);'
                }
                {
                    block: 'move_toward(x);'
                }
                {
                    block: 'cast(x);'
                }
                {
                    block: 'strike();'
                }
                {
                    block: 'nock();'
                }
                {
                    block: 'loose();'
                }
                {
                    block: 'start_shooting();'
                }
                {
                    block: 'stop_shooting();'
                }
            ]
        }
        {
            name: 'Data'
            color: 'yellow'
            blocks: [
                {
                    block: 'var x = 0;'
                }
                {
                    block: 'x = 1;'
                }
                {
                    block: '[]'
                }
                {
                    block: 'list[i]'
                }
                {
                    block: 'x.length'
                }
                {
                    block: 'list.push(x)'
                }
                {
                    block: 'list.filter(function(x) {\n  \n})'
                }
                {
                    block: 'list.map(function(x) {\n  \n})'
                }
            ]
        }
    ]
}
ace_editor.setValue SCRIPTS[character_templates[0]].ai, -1

currently_editing = 0

prototype_list = document.getElementById('prototype-list')
enemy_prototype_list = document.getElementById('enemy-prototype-list')

script_elements = null
selected_element = null
enemy_script_elements = null
enemy_selected_element = null

context_menu = document.getElementById 'context-menu'

contexted_element = null
contexted_index = null

document.body.addEventListener 'click', (event) ->
    context_menu.style.display = 'none'
    contexted_element?.className = contexted_element.className.split(' ').filter((x) -> x isnt 'contexted').join(' ')
    contexted_element = null

document.body.oncontextmenu = (event) ->
    return false

update_prototype_list = ->
    script_elements = []
    selected_element = null

    prototype_list.innerHTML = ''
    for script, i in SCRIPTS then do (script, i) ->
        element = document.createElement 'div'
        element.className = 'script-' + script.class
        element.innerText = script.name

        wrapper = document.createElement 'div'
        wrapper.className = 'button'
        wrapper.appendChild element

        wrapper.oncontextmenu = (event) ->
            context_menu.style.display = 'block'
            context_menu.style.left = event.clientX
            context_menu.style.top = event.clientY

            contexted_element?.className = contexted_element.className.split(' ').filter((x) -> x isnt 'contexted').join(' ')
            wrapper.className += ' contexted'
            console.log 'setting contexted element to', wrapper
            contexted_element = wrapper
            contexted_index = i

            return false

        script_elements.push wrapper

        prototype_list.appendChild wrapper

        element.addEventListener 'click', ->
            selected_element?.className = selected_element.className.split(' ')[0]
            wrapper.className += ' selected'
            selected_element = wrapper
            character_templates[currently_editing] = i

            save_settings()

            ace_editor.setValue SCRIPTS[i].ai, -1
            do rerender_tabs

    enemy_script_elements = []
    enemy_selected_element = null

    enemy_prototype_list.innerHTML = ''
    for script, i in SCRIPTS then do (script, i) ->
        element = document.createElement 'div'
        element.className = 'script-' + script.class
        element.innerText = script.name

        wrapper = document.createElement 'div'
        wrapper.className = 'button'
        wrapper.appendChild element

        enemy_script_elements.push wrapper

        enemy_prototype_list.appendChild wrapper

        element.addEventListener 'click', ->
            enemy_selected_element?.className = selected_element.className.split(' ')[0]
            wrapper.className += ' selected'
            enemy_selected_element = wrapper
            enemy_templates[enemy_currently_editing] = i

            save_settings()

            do rerender_enemy_tabs

do update_prototype_list

database = firebase.database()
save_timeout = null
save = ->
    if save_timeout?
        clearTimeout save_timeout
    save_timeout = setTimeout (->
        # Save scripts
        database.ref("/scripts/#{CURRENT_USER.uid}").set SCRIPTS.map (x) -> [x.name, x.class, x.ai]
    ), 150

save_settings_timeout = null
save_settings = ->
    if save_settings_timeout?
        clearTimeout save_settings_timeout
    save_settings_timeout = setTimeout (->
        # Save scripts
        database.ref("/settings/#{CURRENT_USER.uid}").set {character_templates, enemy_templates}
    ), 150

ace_editor.on 'change', ->
    SCRIPTS[character_templates[currently_editing]].ai = ace_editor.getValue()
    do save

ace_editor.aceEditor.on 'change', ->
    SCRIPTS[character_templates[currently_editing]].ai = ace_editor.getValue()
    do save

CURRENT_MODE = 'PRACTICE'

edit_screen = (from) ->
    CURRENT_MODE = from

    document.getElementById('edit-screen-header').innerText = from
    if from is 'PRACTICE'
        document.getElementById('edit-choose-enemy').style.display = 'block'
    else
        document.getElementById('edit-choose-enemy').style.display = 'none'

    if from is 'CUSTOM'
        document.getElementById('begin').innerText = 'CHOOSE ENEMY'
    else
        document.getElementById('begin').innerText = 'BEGIN'

    document.getElementById('win-screen').style.display = 'none'
    document.getElementById('edit-screen').style.display = 'block'
    document.getElementById('lose-screen').style.display = 'none'
    document.getElementById('main-menu').style.display = 'none'

    ace_editor.setValue SCRIPTS[character_templates[currently_editing]].ai, -1

    do rerender_tabs

IMAGE_URLS = {
    'Mage': 'mage-prototype.png'
    'Knight': 'knight-prototype.png'
    'Rogue': 'rogue-prototype.png'
    'Archer': 'archer-prototype.png'
    'mage': 'mage-prototype.png'
    'knight': 'knight-prototype.png'
    'rogue': 'rogue-prototype.png'
    'archer': 'archer-prototype.png'
}

rerender_tabs = ->
    for template, i in character_templates
        document.getElementById("edit-tab-#{i + 1}").style.backgroundImage = "url(\"#{IMAGE_URLS[SCRIPTS[template].class]}\")"

rerender_enemy_tabs = ->
    for template, i in enemy_templates
        document.getElementById("enemy-tab-#{i + 1}").style.backgroundImage = "url(\"evil-#{IMAGE_URLS[SCRIPTS[template].class]}\")"

do rerender_enemy_tabs

edit_tab_elements = []
selected_tab_element = null
for i in [0...4] then do (i) ->
    edit_tab_elements[i] = document.getElementById("edit-tab-#{i + 1}")
    edit_tab_elements[i].addEventListener 'click', (x) ->
        selected_tab_element.className = selected_tab_element.className.split(' ')[0]
        selected_tab_element = edit_tab_elements[i]
        selected_tab_element.className += ' selected-tab'

        currently_editing = i

        element = script_elements[character_templates[i]]
        selected_element?.className = selected_element.className.split(' ')[0]
        element.className += ' selected'
        selected_element = element

        ace_editor.setValue SCRIPTS[character_templates[i]].ai, -1

enemy_currently_editing = 0
enemy_tab_elements = []
enemy_selected_tab_element = null
for i in [0...4] then do (i) ->
    enemy_tab_elements[i] = document.getElementById("enemy-tab-#{i + 1}")
    enemy_tab_elements[i].addEventListener 'click', (x) ->
        enemy_selected_tab_element.className = enemy_selected_tab_element.className.split(' ')[0]
        enemy_selected_tab_element = enemy_tab_elements[i]
        enemy_selected_tab_element.className += ' selected-tab'

        enemy_currently_editing = i

        element = enemy_script_elements[enemy_templates[i]]
        enemy_selected_element?.className = enemy_selected_element.className.split(' ')[0]
        element.className += ' selected'
        enemy_selected_element = element

element = enemy_script_elements[enemy_templates[0]]
enemy_selected_element?.className = enemy_selected_element.className.split(' ')[0]
enemy_selected_element = element
element.className += ' selected'

element = script_elements[character_templates[0]]
selected_element?.className = selected_element.className.split(' ')[0]
selected_element = element
element.className += ' selected'

selected_tab_element = edit_tab_elements[0]
enemy_selected_tab_element = enemy_tab_elements[0]

document.getElementById('main-menu-win').addEventListener 'click', main_menu
document.getElementById('main-menu-lose').addEventListener 'click', main_menu
document.getElementById('practice').addEventListener 'click', -> edit_screen 'PRACTICE'
document.getElementById('random').addEventListener 'click', -> edit_screen 'RANDOM'
document.getElementById('custom').addEventListener 'click', -> edit_screen 'CUSTOM'
document.getElementById('begin').addEventListener 'click', ->
    if CURRENT_MODE is 'PRACTICE'
        play_game CURRENT_USER.uid, enemy_templates.map (x, i) -> instantiate_character SCRIPTS[x], i, false


    else if CURRENT_MODE is 'RANDOM'
        database.ref('/settings').once('value').then (e) ->
            settings = e.val()

            # Pick a random settings
            candidates = []
            for key of settings when key isnt CURRENT_USER.uid
                candidates.push key

            chosen_opponent = candidates[Math.floor Math.random() * candidates.length]

            database.ref("/scripts/#{chosen_opponent}").once('value').then (script_snapshot) ->
                enemy_scripts = script_snapshot.val().map (x) -> new Script x[0], x[1], x[2]

                play_game chosen_opponent, settings[chosen_opponent].character_templates.map (x, i) ->
                    console.log enemy_scripts[x], i
                    instantiate_character enemy_scripts[x], i, false
    else
        alert 'oops I do not know how to do that'
        return

document.getElementById('back').addEventListener 'click', main_menu

class_elements = {
    'Mage': document.getElementById('mage-select'),
    'Rogue': document.getElementById('rogue-select'),
    'Knight': document.getElementById('knight-select'),
    'Archer': document.getElementById('archer-select')
}

selected_class_element = class_elements['Knight']
selected_class = 'Knight'

class_elements['Archer'].addEventListener 'click', ->
    selected_class_element.style.backgroundColor = ''
    selected_class_element = class_elements['Archer']
    selected_class_element.style.backgroundColor = '#888'

    selected_class = 'Archer'

class_elements['Rogue'].addEventListener 'click', ->
    selected_class_element.style.backgroundColor = ''
    selected_class_element = class_elements['Rogue']
    selected_class_element.style.backgroundColor = '#888'

    selected_class = 'Rogue'

class_elements['Knight'].addEventListener 'click', ->
    selected_class_element.style.backgroundColor = ''
    selected_class_element = class_elements['Knight']
    selected_class_element.style.backgroundColor = '#888'

    selected_class = 'Knight'

class_elements['Mage'].addEventListener 'click', ->
    selected_class_element.style.backgroundColor = ''
    selected_class_element = class_elements['Mage']
    selected_class_element.style.backgroundColor = '#888'

    selected_class = 'Mage'

document.getElementById('new').addEventListener 'click', ->
    document.getElementById('dialog-screen').style.display = 'block'
    document.getElementById('name').value = ''

    selected_class = 'Knight'
    selected_class_element.style.backgroundColor = ''
    selected_class_element = class_elements['Knight']
    selected_class_element.style.backgroundColor = '#888'

document.getElementById('create').addEventListener 'click', ->
    document.getElementById('dialog-screen').style.display = ''

    SCRIPTS.push new Script document.getElementById('name').value, selected_class, ''

    do update_prototype_list
    do save

document.getElementById('delete').addEventListener 'click', ->
    SCRIPTS.splice contexted_index, 1
    character_templates = character_templates.map (x) -> if x >= contexted_index then x - 1 else x
    enemy_templates = enemy_templates.map (x) -> if x >= contexted_index then x - 1 else x

    save_settings()

    do update_prototype_list
    do rerender_tabs
    do save

document.getElementById('registration-link').addEventListener 'click', registration_screen
document.getElementById('signin-link').addEventListener 'click', login_screen

document.getElementById('register').addEventListener 'click', ->
    email = document.getElementById('registration-email').value
    password = document.getElementById('registration-password').value
    retype = document.getElementById('registration-retype').value

    if password is retype
        firebase.auth().createUserWithEmailAndPassword(email, password).catch (err) ->
            alert err
    else
        alert 'passwords are not the same'

document.getElementById('login').addEventListener 'click', ->
    email = document.getElementById('email').value
    password = document.getElementById('password').value

    firebase.auth().signInWithEmailAndPassword(email, password).catch (err) ->
        alert err

github_provider = new firebase.auth.GithubAuthProvider()
document.getElementById('github-in').addEventListener 'click', ->
    firebase.auth().signInWithPopup(github_provider).catch (err) ->
        alert err

google_provider = new firebase.auth.GoogleAuthProvider()
document.getElementById('google-in').addEventListener 'click', ->
    firebase.auth().signInWithPopup(google_provider).catch (err) ->
        alert err

document.getElementById('logout').addEventListener 'click', ->
    firebase.auth().signOut()

CURRENT_USER = null
firebase.auth().onAuthStateChanged (user) ->
    if user
        CURRENT_USER = user
        load_scripts()
        load_settings()
        main_menu()
    else
        login_screen()

# NAME GENERATION
name_syllables = [
    'tal',
    'til',
    'tol',
    'al',
    'par',
    'in',
    'kron'
    'kor',
    'kar',
    'kur',
    'kir',
    'ker',
    'tar',
    'ter',
    'tir',
    'tur',
    'tor'
    'el',
    'lan',
    'star',
    'pril',
    'por',
    'par',
    'pir'
    'pyl',
    'pros',
    'gyr'
    'xel'
    'tril'
    'tris'
    'fel'
    'fer'
    'fen'
    'fin'
]

ending_syllables = [
    'eon',
    'on',
    'ea',
    'ae',
    'a',
    'us',
    'eus',
    'ius'
    'is',
    'os',
    'ys'
]

generate_name = (seed) ->
    rng = new Math.seedrandom seed

    # Name is 2-4 syllables. One of them is the ending one.
    length = Math.floor rng() * 4

    str = ''
    for [1..length]
        str += name_syllables[Math.floor rng() * name_syllables.length]
    str += ending_syllables[Math.floor rng() * ending_syllables.length]

    str = str[0].toUpperCase() + str[1..]
    return str
