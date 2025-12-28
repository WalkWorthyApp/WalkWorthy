export interface UserProfileInput {
  ageRange?: string;
  major?: string;
  gender?: string;
  hobbies?: string[];
  optInTailored: boolean;
}

export interface DeviceRegistrationInput {
  deviceId: string;
  platform: 'ios' | 'android';
  appVersion?: string;
  notificationToken?: string;
}

export interface EncouragementPayload {
  id: string;
  ref: string;
  text: string;
  encouragement: string;
  translation?: string;
  expiresAtIso: string;
}
