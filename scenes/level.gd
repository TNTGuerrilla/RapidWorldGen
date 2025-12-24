extends Node2D

# --- Configuration Variables ---
# These variables control the behavior of the world generation.
# @export allows them to be edited in the Godot Inspector.

# The seed for the noise generator. If 0, a random seed is picked at runtime.
@export var noise_seed: int = 0
# The width/height of a chunk in tiles. 16x16 is standard.
@export var chunk_size: int = 16
# How many chunks away from the player to draw (visual range).
@export var render_distance: int = 5
# How many chunks away from the player to generate data for (logic range).
# Should be larger than render_distance to prevent "pop-in" of data logic.
@export var generation_distance: int = 8
# The frequency of the FastNoiseLite generator.
# Lower values = larger features (continents). Higher values = smaller features (islands).
@export var noise_frequency: float = 0.001 
# If true, draws a colored square under the terrain to visualize the noise values.
@export var debug_noise_layer: bool = false
# Probability (0.0 to 1.0) of a tree spawning on valid terrain. 0.003 = 0.3%.
@export var tree_freq: float = 0.003
# How jagged or smooth the noise is. lower number smoother.
@export var fractal: int = 7
# How many chunks to render in per frame.
@export var render_budget: int = 2

# References to child nodes.
@onready var tile_map: TileMap = $TileMap
@onready var player: Node2D = $Player

# The noise generator instance.
var noise: FastNoiseLite = FastNoiseLite.new()

# --- Data Caches ---
# These Dictionaries store the world data to avoid re-calculating it.

# terrain_data stores the abstract "Type" of terrain at a coordinate.
# Key: Vector2i (Global Cell Position) 
# Value: Dictionary { layer_id: int -> terrain_id: int }
var terrain_data: Dictionary = {}

# terrain_atlas_coords stores the specific TileSet coordinates to draw.
# This is the result of the "Autotiling" solver.
# Key: Vector2i (Global Cell Position)
# Value: Dictionary { layer_id: int -> atlas_coords: Vector3i }
# Vector3i: x, y = atlas coordinates in the texture, z = alternative tile ID (for flipping).
var terrain_atlas_coords: Dictionary = {}

# Mutex to protect data caches from being accessed by the main thread and generation thread simultaneously.
var data_mutex: Mutex = Mutex.new()

# --- Chunk Management ---
var drawn_chunks: Dictionary = {} # Set of chunks currently visible on the TileMap.
var chunks_being_generated: Dictionary = {} # Set of chunks currently being processed by the thread pool.
var chunks_to_draw: Array[Vector2i] = [] # Queue of chunks waiting to be drawn to the TileMap.

# Used to protect chunks_being_generated when multiple threads access it.
var generation_mutex: Mutex = Mutex.new()

# Debug Visualization
var debug_container: Node2D
var debug_sprites: Dictionary = {} # Key: chunk -> Value: Sprite2D

# --- Autotiling Rules ---
# This dictionary looks up valid tiles for a terrain type.
# We build this manually from the TileSet data to allow for custom "fuzzy" matching
# (e.g., A dirt path can connect to a stone road without a hard border).
# Format: terrain_id -> Array of { "coords": Vector2i, "peering": Dictionary, "score": int, "prob": float }
var tile_rules: Dictionary = {}

# Standard neighbor directions for 3x3 bitmasking (Autotiling).
const NEIGHBORS = [
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_TOP_SIDE,
	TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER
]

# --- Constants ---
# Layer IDs correspond to the physical layers in the TileMap node.
const LAYER_WATER = 0
const LAYER_SAND = 1
const LAYER_GRASS = 2
const LAYER_CLIFF = 3
const LAYER_ENV = 4

# Terrain IDs match the custom terrain types defined in the TileSet resource.
const TERRAIN_WATER = 0
const TERRAIN_SAND = 1
const TERRAIN_GRASS = 2
const TERRAIN_CLIFF = 3

# Atlas coordinates for tree tiles.
const TREE_PALM_1 = Vector2i(12, 2)
const TREE_PALM_2 = Vector2i(15, 2)
const TREE_FOREST = Vector2i(15, 6)

func _ready() -> void:
	# Initialize random seed if not set in Inspector.
	if noise_seed == 0:
		noise_seed = randi()
	
	# Create a container for debug sprites (draws underneath the map).
	debug_container = Node2D.new()
	debug_container.name = "DebugNoise"
	debug_container.z_index = 4 
	add_child(debug_container)
	
	# Configure FastNoiseLite.
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = noise_frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = fractal
	
	# --- Safe Spawn Logic ---
	# Before starting generation, find a valid spot for the player.
	# We search spirally from (0,0) until we find land (Sand/Grass).
	var spawn_pos = _find_safe_spawn()
	if player:
		player.position = spawn_pos
	
	# Pre-calculate autotiling rules and setup flip alternatives.
	_build_tile_rules()
	_setup_tree_alternatives()

# Creates flipped versions of tree tiles if they don't exist.
# This allows us to reuse the same tree art facing left or right.
func _setup_tree_alternatives() -> void:
	var source: TileSetAtlasSource = tile_map.tile_set.get_source(0)
	for coords in [TREE_PALM_1, TREE_PALM_2, TREE_FOREST]:
		# Check if alternative 1 (flipped) already exists, if not create it.
		if source.get_alternative_tiles_count(coords) < 2:
			var alt_id = 1
			source.create_alternative_tile(coords, alt_id)
			var tile_data = source.get_tile_data(coords, alt_id)
			tile_data.flip_h = true

# Analyzes the TileSet to build a lookup table for autotiling.
# This replaces Godot's built-in terrain system with a custom one for more control.
func _build_tile_rules() -> void:
	var source: TileSetAtlasSource = tile_map.tile_set.get_source(0)
	var tiles_count = source.get_tiles_count()
	
	for i in range(tiles_count):
		var coords = source.get_tile_id(i)
		var tile_data = source.get_tile_data(coords, 0)
		
		var terrain = tile_data.get_terrain()
		if terrain == -1:
			continue # Skip tiles with no terrain set.
			
		if not tile_rules.has(terrain):
			tile_rules[terrain] = []
			
		# Store the peering bits (what neighbors this tile expects).
		var rule = {
			"coords": coords,
			"peering": {},
			"prob": tile_data.probability # Read probability from editor
		}
		
		var score = 0
		for bit in NEIGHBORS:
			var peering_terrain = tile_data.get_terrain_peering_bit(bit)
			if peering_terrain != -1:
				rule["peering"][bit] = peering_terrain
				score += 1 # More specific rules get higher scores.
		
		rule["score"] = score
		tile_rules[terrain].append(rule)
	
	# Sort rules by specificity (descending score).
	# This ensures we try to match corners/edges before generic center tiles.
	for terrain in tile_rules:
		tile_rules[terrain].sort_custom(func(a, b): return a["score"] > b["score"])

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		if debug_container:
			debug_container.visible = not debug_container.visible

# Main Loop: Calculates which chunks need to be generated or drawn based on player position.
func _process(_delta: float) -> void:
	if not player: return
	
	# Convert player position to chunk coordinates.
	var player_pos = tile_map.local_to_map(player.position)
	var current_chunk = Vector2i(floor(player_pos.x / float(chunk_size)), floor(player_pos.y / float(chunk_size)))
	
	# 1. Schedule Generation (Logic Range)
	for x in range(current_chunk.x - generation_distance, current_chunk.x + generation_distance + 1):
		for y in range(current_chunk.y - generation_distance, current_chunk.y + generation_distance + 1):
			var chunk = Vector2i(x, y)
			
			generation_mutex.lock()
			var already_generating = chunks_being_generated.has(chunk)
			generation_mutex.unlock()
			
			if not already_generating:
				data_mutex.lock()
				# Check if we already have data for this chunk.
				var done = terrain_atlas_coords.has(chunk * chunk_size)
				data_mutex.unlock()
				
				if not done:
					generation_mutex.lock()
					chunks_being_generated[chunk] = true
					generation_mutex.unlock()
					# Add task to the built-in WorkerThreadPool
					WorkerThreadPool.add_task(_generate_chunk.bind(chunk))

	# 2. Schedule Drawing (Visual Range)
	var draw_radius_chunks = []
	for x in range(current_chunk.x - render_distance, current_chunk.x + render_distance + 1):
		for y in range(current_chunk.y - render_distance, current_chunk.y + render_distance + 1):
			draw_radius_chunks.append(Vector2i(x, y))
	
	for chunk in draw_radius_chunks:
		# If within render distance, but not drawn yet...
		if not drawn_chunks.has(chunk) and not chunks_to_draw.has(chunk):
			data_mutex.lock()
			# Verify data exists before trying to draw.
			var coords_exist = terrain_atlas_coords.has(chunk * chunk_size)
			data_mutex.unlock()
			if coords_exist:
				chunks_to_draw.append(chunk)
	
	# 3. Unload Chunks (Cleanup)
	var chunks_to_undraw = []
	for chunk in drawn_chunks:
		if chunk not in draw_radius_chunks:
			chunks_to_undraw.append(chunk)
	for chunk in chunks_to_undraw:
		_undraw_chunk(chunk)
	
	# 4. Execute Draw (Budgeted)
	# Only draw a few chunks per frame to avoid lag spikes.
	var budget = render_budget
	while not chunks_to_draw.is_empty() and budget > 0:
		_draw_chunk(chunks_to_draw.pop_front())
		budget -= 1

# Apply the calculated tiles to the TileMap.
func _draw_chunk(chunk: Vector2i) -> void:
	var start_pos = chunk * chunk_size
	data_mutex.lock()
	for x in range(chunk_size):
		for y in range(chunk_size):
			var pos = start_pos + Vector2i(x, y)
			if terrain_atlas_coords.has(pos):
				var layers = terrain_atlas_coords[pos]
				for layer in layers:
					var data = layers[layer]
					# set_cell parameters: layer, position, source_id (0), atlas_coords, alternative_id
					tile_map.set_cell(layer, pos, 0, Vector2i(data.x, data.y), data.z)
	data_mutex.unlock()
	drawn_chunks[chunk] = true
	
	# Generate and attach the debug noise texture if enabled.
	var texture = _create_debug_texture(chunk)
	if texture:
		var sprite = Sprite2D.new()
		sprite.texture = texture
		sprite.scale = Vector2(16, 16) # Scale 1px to 16px tile size
		sprite.centered = false
		sprite.position = Vector2(chunk * chunk_size * 16)
		debug_container.add_child(sprite)
		debug_sprites[chunk] = sprite

# Remove a chunk from the TileMap to save memory/performance.
func _undraw_chunk(chunk: Vector2i) -> void:
	drawn_chunks.erase(chunk)
	var start_pos = chunk * chunk_size
	for x in range(chunk_size):
		for y in range(chunk_size):
			var pos = start_pos + Vector2i(x, y)
			for i in range(tile_map.get_layers_count()): 
				tile_map.erase_cell(i, pos)
	
	if debug_sprites.has(chunk):
		debug_sprites[chunk].queue_free()
		debug_sprites.erase(chunk)

# Generates a small texture representing the raw noise values for debugging.
func _create_debug_texture(chunk: Vector2i) -> ImageTexture:
	#if not debug_noise_layer: return null
	
	var img = Image.create(chunk_size, chunk_size, false, Image.FORMAT_RGBA8)
	var start_pos = chunk * chunk_size
	
	for x in range(chunk_size):
		for y in range(chunk_size):
			var pos = start_pos + Vector2i(x, y)
			var n = noise.get_noise_2d(pos.x, pos.y)
			var color = Color.BLACK
			
			# Match these values with the biome layer values below 
			if n < 0.0:
				color = Color(0, 0, 0.8, 0.25) # Deep Blue (Water)
			elif n < 0.15:
				color = Color(0.8, 0.8, 0.2, 0.25) # Yellow (Sand)
			elif n < 0.535:
				color = Color(0.2, 0.8, 0.2, 0.25) # Green (Grass)
			else:
				color = Color(0.5, 0.5, 0.5, 0.25) # Grey (Cliff)
				
			img.set_pixel(x, y, color)
			
	return ImageTexture.create_from_image(img)

# --- The Core Generation Logic ---
func _generate_chunk(chunk: Vector2i) -> void:
	var start_pos = chunk * chunk_size
	
	# Step 1: Generate Terrain IDs per Layer based on Noise
	# This determines "What" type of terrain is at X,Y (Sand, Grass, etc.)
	var chunk_ids = {} # pos -> { layer_id -> terrain_id }
	
	# We generate a buffer around the chunk so edges connect seamlessly.
	var gen_buffer = 3 
	
	for x in range(-gen_buffer, chunk_size + gen_buffer):
		for y in range(-gen_buffer, chunk_size + gen_buffer):
			var pos = start_pos + Vector2i(x, y)
			var n = noise.get_noise_2d(pos.x, pos.y)
			
			var cell_layers = {}
			
			# Determine biomes based on noise thresholds.
			
			# Layer 0: Water (Everywhere below 0.0)
			if n < 0.0:
				cell_layers[LAYER_WATER] = TERRAIN_WATER
			
			# Layer 1: Sand (Shoreline)
			# Overlaps slightly with water for smooth transitions.
			if n > -0.025 and n < 0.15:
				cell_layers[LAYER_SAND] = TERRAIN_SAND
			
			# Layer 2: Grass (Inland)
			# Overlaps slightly with sand for smooth transitions.
			if n > 0.135 and n < .55:
				cell_layers[LAYER_GRASS] = TERRAIN_GRASS
				
			# Layer 3: Cliff (High ground)
			# Overlaps slightly with grass for smooth transitions.
			if n > 0.535:
				cell_layers[LAYER_CLIFF] = TERRAIN_CLIFF
			
			chunk_ids[pos] = cell_layers
	
	# Commit IDs to the shared cache so other chunks can see them (for neighbor checks).
	data_mutex.lock()
	for pos in chunk_ids:
		terrain_data[pos] = chunk_ids[pos]
	data_mutex.unlock()
	
	# Step 2: Solver (Autotiling)
	# Converts "Terrain Type" -> "Specific Tile Coordinate"
	var chunk_coords = {} # pos -> { layer_id -> coords }
	
	# Pre-fetch neighbors for the entire chunk to avoid mutex locking per-tile.
	var chunk_neighbors = {}
	
	data_mutex.lock()
	for x in range(chunk_size):
		for y in range(chunk_size):
			var pos = start_pos + Vector2i(x, y)
			var neighbor_terrains = {}
			for bit in NEIGHBORS:
				var n_pos = tile_map.get_neighbor_cell(pos, bit)
				# If neighbor isn't generated yet, assume empty (or handle gracefully).
				if terrain_data.has(n_pos):
					neighbor_terrains[bit] = terrain_data[n_pos].values()
				else:
					neighbor_terrains[bit] = []
			chunk_neighbors[pos] = neighbor_terrains
	data_mutex.unlock()
	
	# Solve each tile
	for x in range(chunk_size):
		for y in range(chunk_size):
			var pos = start_pos + Vector2i(x, y)
			var layers = chunk_ids[pos]
			var resolved_layers = {}
			
			for layer_id in layers:
				var type = layers[layer_id]
				
				# Special Override: Deep Water visuals
				if layer_id == LAYER_WATER and type == TERRAIN_WATER:
					var n = noise.get_noise_2d(pos.x, pos.y)
					# If very deep, use a specific dark water tile.
					if n < -0.2:
						resolved_layers[layer_id] = Vector3i(0, 1, 0)
						continue
				
				if not tile_rules.has(type):
					continue
				
				# Autotiling Logic: Find the rule that best matches neighbors.
				var candidates = []
				var best_score = -1
				
				var rules = tile_rules[type]
				var neighbor_terrains = chunk_neighbors[pos]
				
				for rule in rules:
					# Optimization: Rules are sorted by score.
					if not candidates.is_empty() and rule["score"] < best_score:
						break
						
					var fail = false
					var peering = rule["peering"]
					for bit in peering:
						var req = peering[bit]
						var has_neighbor = neighbor_terrains[bit].has(req)
						
						# Special Logic: "Connects To"
						# Allow Sand to connect to Grass (treat Grass as if it were Sand for the border).
						if not has_neighbor:
							if type == TERRAIN_SAND and req == TERRAIN_SAND:
								if neighbor_terrains[bit].has(TERRAIN_GRASS):
									has_neighbor = true
						
						if not has_neighbor:
							fail = true
							break
					
					if not fail:
						if candidates.is_empty():
							best_score = rule["score"]
						candidates.append(rule)
				
				# Select one of the valid candidates (Weighted Random) to add variation.
				if not candidates.is_empty():
					var res = _pick_weighted(candidates)
					resolved_layers[layer_id] = Vector3i(res.x, res.y, 0)
				elif not rules.is_empty():
					# Fallback to the first rule (usually a single center tile) if nothing matched.
					var res = rules[0]["coords"]
					resolved_layers[layer_id] = Vector3i(res.x, res.y, 0)
			
			chunk_coords[pos] = resolved_layers
			
	# Step 3: Decorations (Trees) - Layer 4
	var decoration_buffer = 2
	
	for x in range(chunk_size):
		for y in range(chunk_size):
			var pos = start_pos + Vector2i(x, y)
			
			# Check probability
			if randf() > tree_freq:
				continue
				
			# Check base terrain
			var is_sand = chunk_ids[pos].has(LAYER_SAND) and not chunk_ids[pos].has(LAYER_GRASS)
			var is_grass = chunk_ids[pos].has(LAYER_GRASS)
			
			# Trees cannot grow on cliffs.
			if chunk_ids[pos].has(LAYER_CLIFF):
				is_sand = false
				is_grass = false
			
			if not (is_sand or is_grass):
				continue
				
			# Proximity Check: Ensure 5x5 area is valid (no cliffs, same terrain type).
			var safe = true
			for bx in range(-decoration_buffer, decoration_buffer + 1):
				for by in range(-decoration_buffer, decoration_buffer + 1):
					var b_pos = pos + Vector2i(bx, by)
					
					data_mutex.lock()
					var has_data = terrain_data.has(b_pos)
					var b_ids = {}
					if has_data: b_ids = terrain_data[b_pos]
					data_mutex.unlock()
					
					if not has_data:
						safe = false; break
					
					if b_ids.has(LAYER_CLIFF): 
						safe = false; break
						
					if is_sand and not b_ids.has(LAYER_SAND):
						safe = false; break
					if is_grass and not b_ids.has(LAYER_GRASS):
						safe = false; break
				
				if not safe: break
			
			if safe:
				# Tree Density Check: Don't spawn too close to other trees.
				var spacing_buffer = 3
				for sx in range(-spacing_buffer, spacing_buffer + 1):
					for sy in range(-spacing_buffer, spacing_buffer + 1):
						if sx == 0 and sy == 0: continue
						var s_pos = pos + Vector2i(sx, sy)
						
						# Check local (this chunk)
						if chunk_coords.has(s_pos) and chunk_coords[s_pos].has(LAYER_ENV):
							safe = false; break
						
						# Check global (neighbor chunks)
						data_mutex.lock()
						if terrain_atlas_coords.has(s_pos) and terrain_atlas_coords[s_pos].has(LAYER_ENV):
							safe = false
						data_mutex.unlock()
						if not safe: break
					if not safe: break

			if safe:
				# Commit Tree
				if not chunk_coords.has(pos): chunk_coords[pos] = {}
				
				var tree_coords = Vector2i.ZERO
				if is_sand:
					# Palm trees have 2 varieties.
					tree_coords = TREE_PALM_1 if randf() > 0.5 else TREE_PALM_2
				elif is_grass:
					tree_coords = TREE_FOREST
				
				# 50% chance to flip horizontally for variety.
				var alt_id = 1 if randf() > 0.5 else 0
				chunk_coords[pos][LAYER_ENV] = Vector3i(tree_coords.x, tree_coords.y, alt_id)

	# Commit final coordinates to the cache for drawing.
	data_mutex.lock()
	for pos in chunk_coords:
		terrain_atlas_coords[pos] = chunk_coords[pos]
	data_mutex.unlock()
	
	# Mark this chunk as no longer being generated
	generation_mutex.lock()
	chunks_being_generated.erase(chunk)
	generation_mutex.unlock()

# Helper: Selects a terrain tile from candidates based on their probability.
func _pick_weighted(candidates: Array) -> Vector2i:
	if candidates.size() == 1:
		return candidates[0]["coords"]
		
	var total_weight = 0.0
	for c in candidates:
		total_weight += c["prob"]
		
	var roll = randf() * total_weight
	var current = 0.0
	for c in candidates:
		current += c["prob"]
		if roll <= current:
			return c["coords"]
			
	return candidates[0]["coords"]

# Helper: Spirals out from (0,0) to find the nearest valid spawn point.
func _find_safe_spawn() -> Vector2:
	var max_radius = 100 # Search radius in tiles
	
	var x = 0
	var y = 0
	var dx = 0
	var dy = -1
	
	for i in range(int(pow(max_radius * 2, 2))):
		if _is_safe_spawn(x, y):
			return tile_map.map_to_local(Vector2i(x, y))
		
		# Spiral math to change direction
		if x == y or (x < 0 and x == -y) or (x > 0 and x == 1 - y):
			var temp = dx
			dx = -dy
			dy = temp
		
		x += dx
		y += dy
			
	return tile_map.map_to_local(Vector2i(0, 0)) # Fallback if nothing found

# Helper: Checks if a coordinate is valid for spawning (Sand or Grass).
func _is_safe_spawn(x: int, y: int) -> bool:
	var n = noise.get_noise_2d(x, y)
	# Range check:
	# Water is < 0.0.
	# Cliffs start at > 0.45.
	# Safe zone is between 0.0 and 0.45.
	return n >= 0.0 and n <= 0.45

# Checks if a global position is walkable based on terrain rules.
# Whitelist approach: If the tile contains any walkable land type (Sand, Grass, Cliff), it is walkable.
# This works regardless of whether Water exists on a lower layer.
func is_tile_walkable(global_pos: Vector2) -> bool:
	var map_pos = tile_map.local_to_map(global_pos)
	
	data_mutex.lock()
	var has_data = terrain_data.has(map_pos)
	var layers = {}
	if has_data:
		layers = terrain_data[map_pos]
	data_mutex.unlock()
	
	if not has_data:
		return false # Prevent walking off the generated map
		
	if layers.has(LAYER_GRASS) or layers.has(LAYER_SAND) or layers.has(LAYER_CLIFF):
		return true
			
	return false