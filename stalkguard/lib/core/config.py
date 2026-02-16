from dataclasses import dataclass

@dataclass(frozen=True)
class PipelineConfig:
    # Türkiye bounding box (yaklaşık)
    lat_min: float = 35.8
    lat_max: float = 42.2
    lon_min: float = 25.6
    lon_max: float = 44.9

    tile_lat_deg: float = 0.02
    tile_lon_deg: float = 0.02

    out_tiles_path: str = "data/built/tr_tiles.bin"
    out_index_path: str = "data/built/tr_index.bin"
