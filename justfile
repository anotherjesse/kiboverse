generate-types:
    cargo run --quiet -p kibo-typegen

check-generated-types:
    cargo run --quiet -p kibo-typegen -- --check
