# Rapid Infinite 2D World Generation - Godot 4.5
This is the fastest 2D infinite procedural generation "engine" built in Godot 4.5.
as
### Introduction + Backstory (skip to next section to find what you actually care about)
Let me introduce myself. I am colloquially known as TNT_Guerrilla. I am a Python programmer who specializes in practical utility software and AI infused programs. I started learning Python in high school, and it has been a hobby of mine since 2016.

Most of what I build comes from wanting something to exist or work better than what I can already find. I tend to focus on tools, automation, and systems that are meant to be used regularly, not just written once and forgotten. I enjoy learning by experimenting, breaking things, and iterating until they behave the way I expect. Over time, my interests have naturally drifted toward writing software that solves problems I actually run into, or creating apps that I want, in a way that is practial to my needs. That usually means small utilities, automation pipelines, or experimenting with AI-driven behavior rather than ready-to-ship programs. I like understanding what’s happening under the hood, and I tend to treat programming as a hands-on process of trial, breaking things, trial again, and eventually refinement.

I've wanted to get into game development for a while now, and finally decided to start. This is my first Godot project. When I started, my goal was to learn as much as I could about the engine and it's capabilities and limitations. My initial idea was to make a top-down shooter game, inspired by various .io games, but I quickly decided I should make some concepts that I could build off of, so I switched my focus from "make a game" to "make a mechanic". I've always been facinated by procedurally generated worlds, so I decided to try to make a real-time proc-gen engine, inspired by Minecraft. After looking at multiple YouTube tutorials, reading Godot documentation and trying to find resources for example code, I found that there are very few examples of infinite world generation, and the resources I did find were very laggy and more of rough proof of concepts than anything usable. Turns out (as of Godot 4.5), Godot really doesn't like to generate thousands of tiles in real time. Every attempt I made resulted in lag spikes, jittering, and all around poor performance. Eventually I came across a github repo that I was able to base this project off of: [NeonfireStudio](https://github.com/NeonfireStudio/2D-Infinite-World-Generation-in-Godot-4)

This was an amazing find, and without it, I probably would've given up on this concept and just called it a "Godot limitation". Using an asset pack I got from a [YouTube tutorial](https://www.youtube.com/playlist?list=PLflAYKtRJ7dwtqA0FsZadrQGal8lWp-MM), I got to work modifying and improving the system.

## Technical Overview
This project serves as a high-performance template for infinite 2D world generation in Godot 4. It focuses on maintaining a smooth 60+ FPS while generating complex, multi-layered terrain and decorations in real-time.

### Key Features
*   **Threaded Generation**: Terrain calculations are offloaded to a background thread using `Thread`, `Mutex`, and `Semaphore`. This eliminates the "lag spikes" typically associated with TileMap generation.
*   **Custom Autotiling Solver**: Instead of relying on Godot's built-in terrain system (which can be difficult to control at scale), this project uses a custom bitmask solver. This allows for "fuzzy" transitions, such as Sand tiles smoothly connecting to Grass without requiring dedicated transition tiles for every combination.
*   **Dynamic Chunk Management**: Uses a Chunk-based system with separate `render_distance` (visual range) and `generation_distance` (data range). Chunks are automatically unloaded when far from the player to save memory.
*   **FastNoiseLite Integration**: Leverages Simplex noise with Fractal FBM for organic-looking continents, islands, and coastlines.
*   **Smart Decoration System**: Trees and environmental objects use proximity and biome checks to ensure they only spawn on valid terrain (e.g., Palms on Sand, Forests on Grass) with natural-looking density.
*   **Safe-Spawn Algorithm**: A spiral search algorithm ensures the player always starts on land, preventing the "spawn in the middle of the ocean" problem common in procedural games.
*   **Top-Down Shooter Logic**: Includes a responsive player controller with mouse-aiming, physics-based projectiles, and an 8-directional animation system.

## Under the Hood: Why is this fast?
The biggest hurdle in infinite generation in Godot is the `TileMap` node itself. Updating thousands of cells takes time. Most tutorials calculate noise and set cells in the same loop, causing massive frame drops as the player moves. This project solves that via a pipeline approach:

1.  **The Threaded Math Layer:** All noise calculations, biome logic, and bitmask neighbor checks happen in a separate thread. This means the heavy math never pauses your game.
2.  **The Main Thread Budget:** Even if the data is ready, asking Godot to draw 5 chunks instantly (1200+ tiles) will stutter the game. We use a **Drawing Budget** (default: 2 chunks per frame). If 10 chunks are ready, the game draws them over 5 frames. This keeps the FPS silky smooth.
3.  **Lookup Tables:** Instead of running complex logic for every tile at runtime, we pre-calculate "Tile Rules" on startup. The generator simply looks up "Sand tile with Right and Bottom neighbors" in a Dictionary, which is practically instant.

## Comparison with Reference & Other Examples
While this project builds on the excellent foundation provided by [NeonfireStudio](https://github.com/NeonfireStudio/2D-Infinite-World-Generation-in-Godot-4), it introduces several key architectural changes designed for production usability and stability:

*   **Robust Threading Model:** The background thread sleeps completely when not needed (using Semaphores), drastically reducing CPU usage compared to simple loop-based checks found in other examples.
*   **Safe Spawn System:** Most infinite map tutorials dump you in the ocean or a wall at (0,0). This project uses a custom spiral-search algorithm that runs before the game starts, guaranteeing the player spawns on valid land.
*   **Decoration Pass:** A dedicated pass for environment (Trees) that respects biomes (Palms on Sand, Forests on Grass) and includes proximity checks to prevent clutter.
*   **Fuzzy Autotiling Logic:** The custom solver allows different biomes to "blend". For example, Sand can treat Grass as a valid neighbor.
	*   *Why this matters:* In a layered rendering approach (Water -> Sand -> Grass), you technically don't *need* this if your tiles are opaque. However, keeping this logic ensures that there are no gaps under transparent corners of tiles, and it makes the system flexible enough to support same-layer blending (like a dirt path merging into a stone road) if you decide to expand the project.
*   **Educational Comments:** As mentioned, every complex block of code is explained. The goal is to demystify *why* we are doing things, not just *how*.

## Usage & Customization
This project is designed to be a template. Here is how you can modify it for your own game:

### 1. Adding New Biomes
Open `level.gd` and look for `_generate_chunk`. You can easily add new layers based on noise values:
```gdscript
# Example: Adding a Snow layer at high noise values
if n > 0.7:
    cell_layers[LAYER_SNOW] = TERRAIN_SNOW
```
*Note: You will need to add `LAYER_SNOW` and `TERRAIN_SNOW` constants and configure the TileSet.*

### 2. Changing Generation Parameters
Select the `World` node in the main scene. You will see exported variables in the Inspector:
*   `Noise Frequency`: Change the "zoom" of the map. Lower numbers make massive continents; higher numbers make archipelagos.
*   `Render Distance`: Adjust based on your target platform's performance.
*   `Tree Freq`: Control the density of vegetation.

### 3. Modifying the Safe Spawn
The `_find_safe_spawn` function in `level.gd` currently looks for Sand or Grass. If you add a "Safe Zone" biome (like a starting village), you can simply update the check in `_is_safe_spawn` to target that specific biome.

## Educational Value
**Note for Beginners:**
One of the primary goals of this project is to be a learning resource. The GDScript files (`level.gd`, `player.gd`, etc.) are **heavily commented**. 

Instead of just showing *what* the code does, the comments explain the **why**—covering complex topics like thread safety, bitmasking, and noise thresholding in a way that is easy to digest. Whether you are looking for a boilerplate for your next game or just trying to understand how infinite worlds work, this project is designed to be readable and instructive.

## Getting Started
1. Clone the repository.
2. Open `project.godot` in Godot 4.5+.

**IMPORTANT: Asset Disclaimer**
This repository uses placeholder graphics to comply with the asset creator's license. The project will run as-is, but with placeholder textured squares (because I'm not a good artist). To install the real assets:
*   Download the asset pack from **[Paradise Asset Pack](https://jackie-codes.itch.io/paradise-asset-pack)**.
*   Extract the contents and overwrite the `Assets/Paradise` folder in this project.
*   The project will now use the intended, high-quality graphics.

3. Run the `level.tscn` scene.
4. Use **WASD** to move and **Mouse** to aim/shoot. Use the **Mouse Wheel** to zoom in and out.
5. Explore the `level.gd` script to see how the magic happens!

## License & Usage
This project is released under the **MIT License**. 

In plain English: You are free to use, modify, and distribute this code in your own projects—commercial or otherwise. 

### **The DBAD Clause:**

I built this because I couldn't find a good resource that was this extensive. If you use this, please don't just slap your name on the script and sell it as your own "revolutionary proc-gen engine". That would make you a dick. Use it to learn, use it as a foundation for your dream game, and if you make something cool, a shout-out or a link back to this repo would be awesome (but not required). Just be a cool human and keep the spirit of open-source alive!


## Credits and Assets
* Youtube tutorial by Jackie_Codes: https://www.youtube.com/playlist?list=PLflAYKtRJ7dwtqA0FsZadrQGal8lWp-MM
* Paradise Asset pack by Jackie_Codes: https://jackie-codes.itch.io/paradise-asset-pack
* Reference GitHub Repo by NeonfireStudio https://github.com/NeonfireStudio/2D-Infinite-World-Generation-in-Godot-4
* Pistol_Sound.mp3: Recorded by Me
* Bullet Sprite: created by Me

#License
