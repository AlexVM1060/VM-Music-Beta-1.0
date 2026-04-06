// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'downloaded_video.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DownloadedVideoAdapter extends TypeAdapter<DownloadedVideo> {
  @override
  final int typeId = 3;

  @override
  DownloadedVideo read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadedVideo(
      videoId: fields[0] as String,
      title: fields[1] as String,
      thumbnailUrl: fields[2] as String,
      channelTitle: fields[3] as String,
      filePath: fields[4] as String,
      plainLyrics: fields[5] as String?,
      syncedLyrics: fields[6] as String?,
      localThumbnailPath: fields[7] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadedVideo obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.videoId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.thumbnailUrl)
      ..writeByte(3)
      ..write(obj.channelTitle)
      ..writeByte(4)
      ..write(obj.filePath)
      ..writeByte(5)
      ..write(obj.plainLyrics)
      ..writeByte(6)
      ..write(obj.syncedLyrics)
      ..writeByte(7)
      ..write(obj.localThumbnailPath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadedVideoAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
