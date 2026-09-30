Conversion
==========

LocalDevStack exposes Pandoc from the Tools image as a host-file conversion command.
Pandoc does not need to be installed on the workstation and the main LocalDevStack
services do not need to be running.

Basic Usage
-----------

Convert one host file to another::

   lds convert docs README.md README.html
   lds convert docs docs/guide.rst guide.docx
   lds convert docs report.docx report.md
   lds convert docs book.md book.epub --toc

The first path is mounted read-only. Only the output directory is mounted writable.
The short-lived conversion container receives no Docker socket, project volumes, or
LocalDevStack networks.

Pandoc Options
--------------

Arguments after the output path are passed to Pandoc without shell flattening::

   lds convert docs README.md README.html --toc --standalone
   lds convert docs report.docx report.md --wrap=none
   lds convert docs book.md book.epub --metadata title="Developer Guide"

An optional ``--`` separator is accepted::

   lds convert docs README.md README.html -- --toc --standalone

``-o`` / ``--output`` is intentionally rejected because LocalDevStack owns the output
path through the second positional argument.

Relative Assets
---------------

Pandoc runs with the input directory as its working directory and with
``--resource-path=/lds-input``. Relative images and other resources next to the input
document therefore remain available during conversion.

Auxiliary file options such as a reference document should use files below the input
directory and refer to them with relative paths.

Overwrite Safety
----------------

Existing output files are not replaced unless ``--force`` is supplied::

   lds convert docs --force README.md README.html

The input and output may not resolve to the same file.

Format Discovery
----------------

The supported readers and writers come from the Pandoc version currently shipped by the
Tools image::

   lds convert docs --list-input-formats
   lds convert docs --list-output-formats
   lds convert docs --version

Pandoc supports many text/document formats, but not every format can be converted to
every other format. PDF output additionally requires a compatible PDF engine; the base
Tools image currently provides Pandoc itself, not a TeX/PDF rendering stack.

Windows and Git Bash
--------------------

The converter normalizes Windows/Git Bash host paths before creating Docker mounts and
disables MSYS argument rewriting for the Docker invocation. Paths containing spaces are
preserved as individual argv values.

Image Conversion
----------------

Raster/image conversion uses ImageMagick from the same Tools image::

   lds convert image photo.jpg photo.png
   lds convert image photo.png photo.webp -- -quality 82 -strip
   lds convert image animation.gif animation.webp
   lds convert image animation.gif preview.jpg

Use ``lds convert image --formats`` to inspect the delegates/formats available in the current image. Static outputs such as JPEG and PNG use the first frame of animated inputs by default; animation-capable GIF/WebP outputs preserve frames when supported.

Audio and Video Conversion
--------------------------

Audio and video conversion use FFmpeg from the Tools image::

   lds convert audio recording.wav recording.mp3
   lds convert audio recording.wav recording.ogg -- -c:a libopus -b:a 128k
   lds convert video recording.mov recording.mp4
   lds convert video recording.mkv recording.webm -- -c:v libvpx-vp9 -crf 32 -b:v 0

The first-class media converter owns one input, overwrite policy, and one output path.
FFmpeg output options are passed after the input as exact argv. LDS reserves ``-i``,
``-y``, and ``-n`` because it owns input/output and ``--force`` behavior.

Inspect FFmpeg capabilities with::

   lds convert audio --formats
   lds convert audio --codecs
   lds convert audio --encoders
   lds convert video --version

For multi-input, concat, capture, or complex filtergraph workflows use the raw Tools
surface instead::

   lds tools ffmpeg ...
   lds tools ffprobe media.mkv

Specialist Media Tools
----------------------

The Tools image also exposes media utilities directly::

   lds tools sox ...
   lds tools soxi recording.wav
   lds tools mkvmerge ...
   lds tools mkvinfo media.mkv
   lds tools mkvextract ...
   lds tools mkvpropedit ...
   lds tools mediainfo media.mkv

``xvidcore`` is installed as an explicit FFmpeg codec runtime dependency; it is a
library rather than a standalone command.
