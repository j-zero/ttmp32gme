# ttmp32gme
a tool to create tiptoi gme files from mp3 files. Also creates a printable sheet to play the music.

## required perl modules (for running ttmp32gme from source)
Path::Class
PAR
Music::Tag::MP3
Music::Tag::OGG
Music::Tag::MusicBrainz
Image::Info

## ToDo
* write better documentation.
* convert mp3->ogg if desired (mainly for older pens with limited memory)
* handle more than 10 tracks for CD booklet (two column track layout)
* upload multiple albums at once
* add and remove music files from library page
* interface to use external ripping tools such as fre:ac
