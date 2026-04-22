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
    return OTPAccount(
      id: fields[0] as String,
      service: fields[1] as String,
      secret: fields[2] as String, // ← ADD THIS LINE - secret is required
      issuer: fields[3] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          fields[4] as int), // ← FIX: convert int to DateTime
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
      ..write(obj.createdAt.millisecondsSinceEpoch); // ← FIX: write as int
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
