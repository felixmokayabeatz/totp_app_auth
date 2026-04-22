// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'otp_account.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class OTPAccountAdapter extends TypeAdapter<OTPAccount> {
  @override
  final int typeId = 0;

  @override
  OTPAccount read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    final rawCreatedAt = fields[4];
    final createdAt = rawCreatedAt is DateTime
        ? rawCreatedAt
        : rawCreatedAt is int
            ? DateTime.fromMillisecondsSinceEpoch(rawCreatedAt)
            : rawCreatedAt is String
                ? DateTime.tryParse(rawCreatedAt) ?? DateTime.now()
                : DateTime.now();
    return OTPAccount(
      id: fields[0] as String,
      service: fields[1] as String,
      secret: fields[2] as String,
      issuer: fields[3] as String?,
      createdAt: createdAt,
      userId: null,
    );
  }

  @override
  void write(BinaryWriter writer, OTPAccount obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.service)
      ..writeByte(2)
      ..write(obj.encryptedSecret)
      ..writeByte(3)
      ..write(obj.issuer ?? '')
      ..writeByte(4)
      ..write(obj.createdAt.millisecondsSinceEpoch);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OTPAccountAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
