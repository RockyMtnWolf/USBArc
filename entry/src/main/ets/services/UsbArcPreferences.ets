import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { UsbBackendMode, UsbIpServerSettings } from '../usb/UsbModels';

export type AutoShareScope = 'all' | 'rules';
export type UsbArcTabBarStyle = 'material' | 'light' | 'dark' | 'accent' | 'image';
export type UsbArcThemeMode = 'system' | 'light' | 'dark';

export interface UsbAutoShareRule {
  id: string;
  vendorIdHex: string;
  productIdHex: string;
  serialNumber: string;
}

export interface UsbArcPreferencesData {
  backendMode: UsbBackendMode;
  host: string;
  port: number;
  autoRequestPermission: boolean;
  autoShare: boolean;
  autoShareScope: AutoShareScope;
  maxClients: number;
  forceClaim: boolean;
  retainClaimsOnStop: boolean;
  backgroundTaskMode: 'off' | 'download' | 'taskKeeping';
  themeMode: UsbArcThemeMode;
  tabBarStyle: UsbArcTabBarStyle;
  tabBarImagePath: string;
  appBackgroundEnabled: boolean;
  rules: Array<UsbAutoShareRule>;
}

const STORE_NAME: string = 'usbarc_settings';
const SETTINGS_KEY: string = 'settings_v1';

export const DEFAULT_USB_ARC_PREFERENCES: UsbArcPreferencesData = {
  backendMode: 'usbManager',
  host: '0.0.0.0',
  port: 3240,
  autoRequestPermission: false,
  autoShare: false,
  autoShareScope: 'all',
  maxClients: 4,
  forceClaim: false,
  retainClaimsOnStop: false,
  backgroundTaskMode: 'off',
  themeMode: 'system',
  tabBarStyle: 'material',
  tabBarImagePath: '',
  appBackgroundEnabled: false,
  rules: []
};

export class UsbArcPreferences {
  static async load(context: common.Context): Promise<UsbArcPreferencesData> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw: string = store.getSync(SETTINGS_KEY, '') as string;
      if (raw.length === 0) {
        return UsbArcPreferences.copy(DEFAULT_USB_ARC_PREFERENCES);
      }
      const parsed: Object = JSON.parse(raw) as Object;
      return UsbArcPreferences.normalize(parsed);
    } catch (_error) {
      return UsbArcPreferences.copy(DEFAULT_USB_ARC_PREFERENCES);
    }
  }

  static async save(context: common.Context, settings: UsbArcPreferencesData): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(SETTINGS_KEY, JSON.stringify(UsbArcPreferences.normalize(settings)));
    await store.flush();
  }

  static toServerSettings(settings: UsbArcPreferencesData): UsbIpServerSettings {
    return {
      backendMode: settings.backendMode,
      host: settings.host,
      port: settings.port,
      autoRequestPermission: settings.autoRequestPermission,
      autoShare: settings.autoShare,
      maxClients: settings.maxClients,
      forceClaim: settings.forceClaim,
      retainClaimsOnStop: settings.retainClaimsOnStop
    };
  }

  static copy(settings: UsbArcPreferencesData): UsbArcPreferencesData {
    return {
      backendMode: settings.backendMode,
      host: settings.host,
      port: settings.port,
      autoRequestPermission: settings.autoRequestPermission,
      autoShare: settings.autoShare,
      autoShareScope: settings.autoShareScope,
      maxClients: settings.maxClients,
      forceClaim: settings.forceClaim,
      retainClaimsOnStop: settings.retainClaimsOnStop,
      backgroundTaskMode: settings.backgroundTaskMode,
      themeMode: settings.themeMode,
      tabBarStyle: settings.tabBarStyle,
      tabBarImagePath: settings.tabBarImagePath,
      appBackgroundEnabled: settings.appBackgroundEnabled,
      rules: settings.rules.map((rule: UsbAutoShareRule): UsbAutoShareRule => ({
        id: rule.id,
        vendorIdHex: rule.vendorIdHex,
        productIdHex: rule.productIdHex,
        serialNumber: rule.serialNumber
      }))
    };
  }

  static normalizeRule(rule: Object): UsbAutoShareRule | undefined {
    if (rule === null || typeof rule !== 'object') {
      return undefined;
    }
    const candidate: Record<string, Object> = rule as Record<string, Object>;
    if (typeof candidate['vendorIdHex'] !== 'string' || typeof candidate['productIdHex'] !== 'string') {
      return undefined;
    }
    const vendorIdHex: string = (candidate['vendorIdHex'] as string).trim().replace(/^0x/i, '').toLowerCase();
    const productIdHex: string = (candidate['productIdHex'] as string).trim().replace(/^0x/i, '').toLowerCase();
    if (!UsbArcPreferences.isHexId(vendorIdHex) || !UsbArcPreferences.isHexId(productIdHex)) {
      return undefined;
    }
    return {
      id: typeof candidate['id'] === 'string' && (candidate['id'] as string).length > 0 ?
        candidate['id'] as string : `${Date.now()}-${vendorIdHex}-${productIdHex}`,
      vendorIdHex: vendorIdHex.padStart(4, '0'),
      productIdHex: productIdHex.padStart(4, '0'),
      serialNumber: typeof candidate['serialNumber'] === 'string' ?
        (candidate['serialNumber'] as string).trim() : ''
    };
  }

  static isHexId(value: string): boolean {
    return /^[0-9a-fA-F]{1,4}$/.test(value);
  }

  static ruleMatches(rule: UsbAutoShareRule, vendorId: number, productId: number,
    serialNumber: string): boolean {
    const normalized: UsbAutoShareRule | undefined = UsbArcPreferences.normalizeRule(rule);
    if (normalized === undefined || Number.parseInt(normalized.vendorIdHex, 16) !== vendorId ||
      Number.parseInt(normalized.productIdHex, 16) !== productId) {
      return false;
    }
    if (normalized.serialNumber.length === 0) {
      return true;
    }
    return serialNumber.length > 0 && serialNumber === normalized.serialNumber;
  }

  private static normalize(value: Object): UsbArcPreferencesData {
    const source = value as Record<string, Object>;
    const rules: Array<UsbAutoShareRule> = [];
    const sourceRules: Object | undefined = source['rules'];
    if (Array.isArray(sourceRules)) {
      sourceRules.forEach((candidate: Object) => {
        if (candidate === null || typeof candidate !== 'object') {
          return;
        }
        const rule: UsbAutoShareRule | undefined = UsbArcPreferences.normalizeRule(candidate);
        if (rule !== undefined && !rules.some((item: UsbAutoShareRule) => item.id === rule.id)) {
          rules.push(rule);
        }
      });
    }
    const scope: string = source['autoShareScope'] as string;
    const backendMode: UsbBackendMode = source['backendMode'] === 'usbDdk' ? 'usbDdk' : 'usbManager';
    const port: number = Number(source['port']);
    const maxClients: number = Number(source['maxClients']);
    return {
      backendMode,
      host: typeof source['host'] === 'string' && (source['host'] as string).length > 0 ?
        source['host'] as string : DEFAULT_USB_ARC_PREFERENCES.host,
      port: Number.isInteger(port) && port > 0 && port <= 65535 ? port : DEFAULT_USB_ARC_PREFERENCES.port,
      autoRequestPermission: source['autoRequestPermission'] === true,
      autoShare: source['autoShare'] === true,
      autoShareScope: scope === 'rules' ? 'rules' : 'all',
      maxClients: Number.isInteger(maxClients) && maxClients > 0 && maxClients <= 32 ?
        maxClients : DEFAULT_USB_ARC_PREFERENCES.maxClients,
      forceClaim: source['forceClaim'] === true,
      retainClaimsOnStop: source['retainClaimsOnStop'] === true,
      backgroundTaskMode: source['backgroundTaskMode'] === 'download' ||
        source['backgroundTaskMode'] === 'taskKeeping' ? source['backgroundTaskMode'] as 'download' | 'taskKeeping' : 'off',
      themeMode: source['themeMode'] === 'light' || source['themeMode'] === 'dark' ?
        source['themeMode'] as UsbArcThemeMode : 'system',
      tabBarStyle: source['tabBarStyle'] === 'light' || source['tabBarStyle'] === 'dark' ||
        source['tabBarStyle'] === 'accent' || source['tabBarStyle'] === 'image' ?
        source['tabBarStyle'] as UsbArcTabBarStyle : 'material',
      tabBarImagePath: typeof source['tabBarImagePath'] === 'string' ? source['tabBarImagePath'] as string : '',
      appBackgroundEnabled: source['appBackgroundEnabled'] === true,
      rules: rules
    };
  }
}
