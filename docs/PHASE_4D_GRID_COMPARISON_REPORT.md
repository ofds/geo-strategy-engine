## Phase 4d: Grid Comparison Results (Phase 4e: both methods use chunk-local)

### Center comparison (Method A vs Method B)

- World (3077854.250, 1944000.000) -> A center (3077653.067, 1944360.000), B center (3077653.067, 1944360.000), MATCH: yes, offset (0.000000, 0.000000) m
- World (3076122.250, 1944000.000) -> A center (3075921.016, 1944360.000), B center (3075921.016, 1944360.000), MATCH: yes, offset (0.000000, 0.000000) m
- World (3077954.250, 1944050.000) -> A center (3077653.067, 1944360.000), B center (3077653.067, 1944360.000), MATCH: yes, offset (0.000000, 0.000000) m
- World (3078000.000, 1944100.000) -> A center (3077653.067, 1944360.000), B center (3077653.067, 1944360.000), MATCH: yes, offset (0.000000, 0.000000) m

### SDF orientation check

- SDF at top vertex (0, 577.35): -0.0000211431983 (should be ~0 if boundary passes through vertex)
- SDF at right edge (500, 0): -0.00000883062501 (should be ~0 if boundary passes through flat edge)

### Axis trace

axial_to_center returns (world_x_component, world_z_component). local_xz = (local_x, local_z). p = local_xz - center = (dx, dz).
hex_sdf (pointy-top): max(dot(abs(p), vec2(0.5, 0.8660254)), abs(p).x) - apothem => 0 at vertex (0, radius) and flat edge (apothem, 0).

### Conclusion

SDF orientation matches pointy-top.
