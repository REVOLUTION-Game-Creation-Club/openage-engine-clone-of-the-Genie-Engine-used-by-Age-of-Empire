# Copyright 2014-2021 the openage authors. See copying.md for legal info.
#
# cython: infer_types=True
# pylint: disable=too-many-locals
"""
Merges texture frames into a spritesheet or terrain tiles into
a terrain texture.
"""
import numpy

from ....log import spam
from ...entity_object.export.texture import TextureImage
from ...service.export.png.binpack import DeterministicPacker
from ...service.export.png.binpack import RowPacker, ColumnPacker, BinaryTreePacker, BestPacker
from ...value_object.read.media.hardcoded.texture import (MAX_TEXTURE_DIMENSION, MARGIN,
                                                          TERRAIN_ASPECT_RATIO)

cimport cython
cimport numpy


def merge_frames(texture, custom_packer=None, cache=None):
    """
    Python wrapper for the Cython function.

    :param texture: Texture containing animation frames.
    :param custom_packer: Packer implementation for efficient packing of frames.
                          If none is specified, the function will try several
                          packer and chooses the most efficient one.
    :param cache: Media cache information with packer settings from a previous run.
    :type texture: Texture
    :type custom_packer: Packer
    :type cache: list
    """
    cmerge_frames(texture, custom_packer, cache)


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef void cmerge_frames(texture, custom_packer=None, cache=None):
    """
    merge all given frames in a texture into a single image atlas.

    :param texture: Texture containing animation frames.
    :param custom_packer: Packer implementation for efficient packing of frames.
                          If none is specified, the function will try several
                          packer and chooses the most efficient one.
    :param cache: Media cache information with packer settings from a previous run.
    :type texture: Texture
    :type custom_packer: Packer
    :type cache: list
    """
    frames = texture.frames
    if len(frames) == 0:
        raise Exception("cannot create texture with empty input frame list")

    if custom_packer:
        packer = custom_packer

    elif cache:
        packer = DeterministicPacker(
            margin=MARGIN,
            hints=cache
        )

    else:
        packer = BestPacker([BinaryTreePacker(margin=MARGIN, aspect_ratio=1),
                             BinaryTreePacker(margin=MARGIN,
                                              aspect_ratio=TERRAIN_ASPECT_RATIO),
                             RowPacker(margin=MARGIN),
                             ColumnPacker(margin=MARGIN)])

    packer.pack(frames)

    cdef int width = packer.width()
    cdef int height = packer.height()
    assert width <= MAX_TEXTURE_DIMENSION, "Texture width limit exceeded"
    assert height <= MAX_TEXTURE_DIMENSION, "Texture height limit exceeded"

    cdef int area = sum(block.width * block.height for block in frames)
    cdef int used_area = width * height
    cdef int efficiency = area / used_area

    spam("merging %d frames to %dx%d atlas, efficiency %.3f.",
         len(frames), width, height, efficiency)

    cdef numpy.ndarray[numpy.uint8_t, ndim=3, mode="c"] atlas_data = \
        numpy.zeros((height, width, 4), dtype=numpy.uint8)
    cdef numpy.uint8_t[:, :, ::1] catlas_data = atlas_data
    cdef numpy.uint8_t[:, :, ::1] csub_frame

    cdef int pos_x
    cdef int pos_y
    cdef int sub_w
    cdef int sub_h

    cdef list drawn_frames_meta = []
    for sub_frame in frames:
        sub_w = sub_frame.width
        sub_h = sub_frame.height

        pos_x, pos_y = packer.pos(sub_frame)

        spam("drawing frame %03d on atlas at %d x %d...",
             len(drawn_frames_meta), pos_x, pos_y)

        # draw the subtexture on atlas_data
        csub_frame = sub_frame.data
        catlas_data[pos_y:pos_y + sub_h, pos_x:pos_x + sub_w] = csub_frame

        hotspot_x, hotspot_y = sub_frame.hotspot

        # generate subtexture meta information dict:
        # origin x, origin y, width, height, hotspot x, hotspot y
        drawn_frames_meta.append(
            {
                "x":  pos_x,
                "y":  pos_y,
                "w":  sub_w,
                "h":  sub_h,
                "cx": hotspot_x,
                "cy": hotspot_y,
            }
        )

    texture.image_data = TextureImage(atlas_data)
    texture.image_metadata = drawn_frames_meta

    spam("successfully merged %d frames to atlas.", len(frames))

    if isinstance(packer, BestPacker):
        # Only generate these values if no custom packer was used
        # TODO: It might make sense to do it anyway for debugging purposes
        texture.best_packer_hints = packer.get_mapping_hints(frames)
