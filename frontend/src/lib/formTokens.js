// Form tokens for the forms restyle (design-spec Revision 2). One source for
// the antd form theme (formTheme) and for styles/forms.css, which declares the
// same values as CSS custom properties on .fs-form. Gold is the iOS Theme.swift
// amber, scoped to form surfaces only (reader and chrome keep their palette).
import { theme } from 'antd';

export const formTokens = {
  gold: '#D4922A',
  goldDim: '#B07820',
  goldLight: '#F0AE40',
  ink: '#1A100A',
  parchment: '#F5EAD0',
  bgPage: '#1E1812',
  cardBg: 'rgba(154,154,154,0.16)',
  cardBorder: 'rgba(255,255,255,0.14)',
  fieldBg: 'rgba(245,234,208,0.06)',
  fieldBorder: 'rgba(245,234,208,0.12)',
  navBg: 'rgba(18,13,8,0.97)',
  dangerBg: 'rgba(40,8,8,0.75)',
  error: '#E06060',
  success: '#4CAF78',
  textPrimary: '#F5EAD0',
  textSecondary: 'rgba(245,234,208,0.55)',
  font: "-apple-system, 'SF Pro Text', system-ui, sans-serif",
};

// Nested ConfigProvider theme for antd controls inside a form surface.
export const formTheme = {
  algorithm: theme.darkAlgorithm,
  token: {
    colorPrimary: formTokens.gold,
    colorTextBase: formTokens.textPrimary,
    colorBgContainer: formTokens.fieldBg,
    colorBgElevated: 'rgba(30,24,18,0.97)',
    colorBorder: formTokens.fieldBorder,
    colorError: formTokens.error,
    colorSuccess: formTokens.success,
    colorLink: formTokens.gold,
    fontFamily: formTokens.font,
    borderRadius: 12,
    borderRadiusLG: 20,
    controlHeight: 48,
    colorBgLayout: 'transparent',
  },
  components: {
    Input: { activeBorderColor: formTokens.gold, hoverBorderColor: formTokens.gold, activeShadow: '0 0 0 3px rgba(212,146,42,0.12)', colorBgContainer: formTokens.fieldBg, colorBorder: formTokens.fieldBorder },
    InputNumber: { activeBorderColor: formTokens.gold, hoverBorderColor: formTokens.gold, activeShadow: '0 0 0 3px rgba(212,146,42,0.12)', colorBgContainer: formTokens.fieldBg },
    Select: { colorBgContainer: formTokens.fieldBg, optionSelectedBg: 'rgba(212,146,42,0.16)', colorBorder: formTokens.fieldBorder },
    DatePicker: { colorBgContainer: formTokens.fieldBg, activeBorderColor: formTokens.gold },
    TimePicker: { colorBgContainer: formTokens.fieldBg, activeBorderColor: formTokens.gold },
    Modal: { contentBg: '#1E1812', headerBg: '#1E1812', footerBg: '#1E1812', borderRadiusLG: 16, titleFontSize: 22, titleColor: formTokens.textPrimary },
    Card: { colorBgContainer: formTokens.cardBg, colorBorderSecondary: formTokens.cardBorder, borderRadiusLG: 20 },
    Button: { primaryColor: formTokens.ink, borderRadius: 24, controlHeight: 44, fontWeight: 700, defaultBorderColor: 'rgba(212,146,42,0.32)', defaultColor: formTokens.gold, defaultBg: 'transparent' },
    Switch: { colorPrimary: formTokens.gold },
    Form: { labelColor: formTokens.textPrimary, labelFontSize: 14, verticalLabelPadding: '0 0 6px' },
  },
};
